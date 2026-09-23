# A single load balancer fronts both the RKE2 API/supervisor and the public
# ingress ports. That works because health check protocol and PROXY-protocol
# are set per evroc_lb_backend_service, not per load balancer: one service per
# port lets TLS API traffic and plain-HTTP ingress each have their own health
# check, so 6443/9345/80/443 share one evroc_loadbalancer + one
# evroc_public_ip without the settings colliding.
#
# Wiring, per the provider docs: loadbalancer.listener.route_refs ->
# lb_l4_route.default_backend_service_ref -> lb_backend_service.backend_pool_ref
# -> lb_backend_pool.backend_refs.

# One pool for every listener: control-plane nodes serve the API, the
# supervisor join, AND the ingress controller (Traefik/nginx runs on the
# control-plane nodes in this design), so there is nothing to gain from
# separate pools.
#
# Legitimately empty on the first apply -- local.control_plane_fqids has no
# nodes yet until control-plane.tf's resources exist. That is expected, not a
# bug: RKE2 servers retry their 9345 supervisor join against the VIP until the
# pool is populated and a backend answers, so an apply that creates the
# network/LB/security-group layer before any node exists still converges once
# the nodes come up in a later apply (or later in the same one).
resource "evroc_lb_backend_pool" "control_plane" {
  name         = "${var.cluster_name}-cp-pool"
  backend_refs = local.control_plane_fqids
  project      = var.project
  region       = var.region
  user_labels  = merge(local.common_labels, { "role" = "loadbalancer" })
}

locals {
  # One entry per listener. health_check_type selects which nested health_check
  # block (tcp vs http) is rendered below. health_check_target is null wherever
  # the check belongs on the service's own port; the resource resolves that to
  # the port rather than passing the null through -- see its target_port.
  lb_services_all = {
    api = {
      port                = 6443
      proxy_protocol      = false
      health_check_type   = "tcp"
      health_check_path   = null
      health_check_target = null
    }
    supervisor = {
      port                = 9345
      proxy_protocol      = false
      health_check_type   = "tcp"
      health_check_path   = null
      health_check_target = null
    }
    # proxy_protocol = true so the ingress controller sees real client IPs
    # instead of the load balancer's own address on every request.
    #
    # target_port = 8080, NOT 80: the ingress controller's 80 entrypoint
    # expects every connection to open with a PROXY header (that's what
    # proxy_protocol above turns on), but evroc's health checker dials the
    # backend directly with a plain HTTP request and sends no such header. Put
    # the check on 80 or 443 and every backend reads back as unhealthy. 8080 is
    # a second, plain-HTTP entrypoint the ingress controller exposes for
    # exactly this purpose, so the check and the real traffic each get the
    # protocol they actually speak.
    #
    # proxy_protocol here and the ingress controller's own "trust PROXY
    # headers from this CIDR" setting are a pair: flip one without the other
    # and the listener breaks -- either the controller rejects connections
    # with an unexpected header, or it trusts none and every log/allowlist/
    # rate-limit in the cluster sees the load balancer's address instead of
    # the real client.
    http = {
      port                = 80
      proxy_protocol      = true
      health_check_type   = "http"
      health_check_path   = "/ping"
      health_check_target = 8080
    }
    https = {
      port                = 443
      proxy_protocol      = true
      health_check_type   = "http"
      health_check_path   = "/ping"
      health_check_target = 8080
    }
  }

  # The http/https services exist only when something is there to serve them.
  # Creating them unconditionally and simply not referencing them from a
  # listener would leave two backend services health-checking port 8080 on
  # every control plane -- a port nothing is listening on when there is no
  # ingress controller -- so every backend reads permanently unhealthy on two
  # services that do nothing. Gate the services, the routes and the listeners
  # on the same condition.
  lb_services = {
    for k, v in local.lb_services_all : k => v
    if var.ingress_controller != "none" || !contains(["http", "https"], k)
  }
}

# Several attributes below restate values the API would have defaulted to
# anyway. They are set explicitly because the provider declares them Optional
# WITHOUT Computed (`terraform providers schema -json` shows
# `"optional": true` and no `"computed"` on ip_protocol_selection, on
# health_check's four tuning fields, and on http.expected_statuses). For such
# an attribute, an absent value in config is a null in the plan -- so the
# server's default comes back on read, Terraform proposes to unset it, the
# server defaults it again, and the diff never converges:
#
#   - ip_protocol_selection = "IPv4" -> null
#   ~ health_check { - interval = "5s" -> null, ... }
#
# That is not cosmetic. A permanently non-empty plan means every apply issues
# an update to all four backend services at once, and these objects use
# Kubernetes-style optimistic concurrency -- the LB controller reconciles the
# siblings while Terraform is mid-write, and the writes lose the race with
# `409 Conflict ... the object has been modified`. Pinning the defaults makes
# the plan empty, which removes the writes, which removes the conflicts.
#
# So: do not "tidy up" these by deleting them. Change them only to values you
# actually want, and re-check that a second plan is empty afterwards -- a new
# provider release that adds Computed would also make them redundant, but
# redundant is harmless here and silence is not.
resource "evroc_lb_backend_service" "cluster" {
  for_each = local.lb_services

  name                  = "${var.cluster_name}-${each.key}-svc"
  port                  = each.value.port
  backend_pool_ref      = evroc_lb_backend_pool.control_plane.fqid
  proxy_protocol        = each.value.proxy_protocol
  ip_protocol_selection = "IPv4"
  project               = var.project
  region                = var.region

  # `listener` names WHICH of the four this is. Worth the extra key: the load
  # balancer fans out into a pool, four services, four routes and four
  # listeners, so a project view shows a dozen near-identical objects whose
  # only distinguishing feature is otherwise a suffix on the name.
  user_labels = merge(local.common_labels, {
    "role"     = "loadbalancer"
    "listener" = each.key
  })

  health_check {
    # NEVER let this go null. The API does not read an absent target_port as
    # "check the service's own port" -- it stores 0, and a health check against
    # port 0 can never pass, so the service ends up with zero healthy backends
    # while every backend is perfectly healthy. The LB then accepts each
    # connection on the listener and resets it immediately:
    #
    #   TLS connect error: error:0A000126:SSL routines::unexpected eof while reading
    #
    # which looks like a broken backend and is not. This cost an afternoon: the
    # API and supervisor listeners were dead (target_port 0) while http/https
    # worked, because those two were the only ones passing an explicit port.
    # The tell is in state: `health_check { target_port = 0 }`.
    target_port = coalesce(each.value.health_check_target, each.value.port)

    # The API's own defaults, restated -- see above. 5s/2s with a single
    # success to mark healthy and two failures to mark unhealthy: a control
    # plane that drops out is taken out of rotation in ~10s, which is the
    # behaviour wanted on the 6443/9345 services during a rolling restart.
    interval            = "5s"
    timeout             = "2s"
    healthy_threshold   = 1
    unhealthy_threshold = 2

    dynamic "tcp" {
      for_each = each.value.health_check_type == "tcp" ? [1] : []
      content {}
    }

    dynamic "http" {
      for_each = each.value.health_check_type == "http" ? [1] : []
      content {
        path = each.value.health_check_path

        # Also an API default, and also not Computed in the provider. The
        # ingress controller's /ping entrypoint answers 200 and nothing else.
        expected_statuses = [200]
      }
    }
  }
}

resource "evroc_lb_l4_route" "cluster" {
  for_each = local.lb_services

  name                        = "${var.cluster_name}-${each.key}-route"
  default_backend_service_ref = evroc_lb_backend_service.cluster[each.key].fqid
  project                     = var.project
  region                      = var.region

  user_labels = merge(local.common_labels, {
    "role"     = "loadbalancer"
    "listener" = each.key
  })
}

locals {
  # One listener per backend service, on the same frontend port the service
  # forwards to. Derived from local.lb_services rather than restating the
  # ingress condition, so the two cannot drift.
  lb_listener_ports = { for k, v in local.lb_services : k => v.port }
}

# backend_network is what makes this load balancer reach its own backends, and
# it is not optional in any useful sense.
#
# Omit it and, in evroc's words, "the Load Balancer will attach to the
# bootstrap networking subnet in each zone" -- the DEFAULT VPC. Every backend
# this module creates lives in evroc_vpc.this, so a load balancer in the
# default VPC has no route to its own backend pool: the VIP accepts the TCP
# connection and immediately resets it, on every listener, forever, while every
# object in the chain reports Ready=True.
#
# The field existed in the API all along but reached the provider only in
# 0.9.4 (2026-09-22), which is why versions.tf pins that as the floor. Before
# it, the load balancer had to be created with the evroc CLI and imported --
# deploy.sh carried a whole "pass 0" for it. That is gone; a bare
# `terraform apply` is now correct from empty state.
#
# It FORCES REPLACEMENT, in the provider and in the API both: editing
# var.vpc_cidr or var.zones destroys and recreates the load balancer, and the
# VIP stops answering for the length of that. Nothing else here behaves that
# way.
resource "evroc_loadbalancer" "cluster" {
  name          = "${var.cluster_name}-lb"
  public_ip_ref = evroc_public_ip.cluster.fqid
  project       = var.project
  region        = var.region
  user_labels   = merge(local.common_labels, { "role" = "loadbalancer" })

  # One subnet per zone, matching evroc_subnet's own for_each over var.zones --
  # a zone missing here is a zone whose backends the load balancer cannot
  # reach, which reads as "that zone's nodes are permanently unhealthy" rather
  # than as a networking error.
  backend_network {
    vpc_ref = evroc_vpc.this.fqid

    dynamic "subnet" {
      for_each = evroc_subnet.this
      content {
        zone       = subnet.key
        subnet_ref = subnet.value.fqid
      }
    }
  }

  dynamic "listener" {
    for_each = local.lb_listener_ports
    content {
      name       = listener.key
      protocol   = "TCP"
      port       = listener.value
      route_refs = [evroc_lb_l4_route.cluster[listener.key].fqid]
    }
  }
}
