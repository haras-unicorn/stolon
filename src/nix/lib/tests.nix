{
  # In seconds. The NixOS test driver waits an hour by default, and a test that
  # needs more than a few minutes is stuck, so every test gets this instead.
  self.lib.tests.globalTimeout = 300;
}
