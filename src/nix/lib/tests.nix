{
  # In seconds. The NixOS test driver waits an hour by default, and a test that
  # needs more than a few minutes is stuck, so every test gets this instead.
  self.lib.tests.globalTimeout = 300;

  # In seconds. The installer test evaluates a machine several times inside its
  # virtual machine and copies a whole system onto a disk, which takes longer
  # than the other tests.
  self.lib.tests.installerTimeout = 1200;
}
