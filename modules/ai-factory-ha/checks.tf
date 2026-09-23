# Post-apply assertions about what the platform actually gave back, as `check`
# blocks rather than as resource postconditions.
#
# WHY NOT A POSTCONDITION, which is the obvious way to write this: a
# postcondition that references `self` is evaluated even when the resource
# FAILED to create, and the reference itself then fails with
#
#   Error: Invalid index
#     condition = contains(keys(self.user_labels), "...")
#   The given key does not identify an element in this collection value.
#
# -- two extra errors per failed instance, explaining nothing, printed
# alongside the real API error and easily mistaken for the cause of it. That is
# not a hypothesis: it is reproducible with any for_each resource whose create
# errors, and try()/can() do NOT suppress it, because the failure happens while
# resolving `self`, before any function sees a value.
#
# A check block is evaluated after the apply, sees only the instances that
# exist, and reports a WARNING instead of an error. Weaker, deliberately: the
# VM is already created either way, so failing the apply afterwards buys
# nothing, and these exist to tell the operator that a platform assumption has
# changed, not to gate anything.

# The elemental image is EFI-only: its GRUB is installed to an ESP and there is
# no BIOS boot path at all. evroc boots a VM in BIOS mode unless the
# compute-experimental-features-UEFI label says otherwise, and a VM that boots
# BIOS simply finds nothing bootable -- it reports Ready, consumes quota, and
# never reaches userspace. The label is EXPERIMENTAL, so evroc may one day stop
# honouring it or rename it; this is what would notice.
check "node_uefi_labels" {
  assert {
    condition = alltrue(concat(
      [for name, vm in evroc_virtual_machine.control_plane : contains(keys(vm.user_labels), "compute-experimental-features-UEFI")],
      [for name, vm in evroc_virtual_machine.gpu : contains(keys(vm.user_labels), "compute-experimental-features-UEFI")],
    ))
    error_message = format(
      "These VMs came back WITHOUT the compute-experimental-features-UEFI label: %s. The elemental image is EFI-only and boots nothing without it -- check whether evroc still honours that experimental feature flag, and expect the affected nodes never to join.",
      join(", ", concat(
        [for name, vm in evroc_virtual_machine.control_plane : name if !contains(keys(vm.user_labels), "compute-experimental-features-UEFI")],
        [for name, vm in evroc_virtual_machine.gpu : name if !contains(keys(vm.user_labels), "compute-experimental-features-UEFI")],
      ))
    )
  }
}
