#include <errno.h>
#include <string.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/mlvalues.h>

typedef void fork_fn(int errors, value v_args);

extern void eio_unix_fork_error(int fd, char *fn, char *msg);

static value val_fork_fn(fork_fn *fn) {
  return caml_copy_nativeint((intnat) fn);
}

static void concurrently_action_setsid(int errors, value v_args) {
  (void) v_args;

  if (setsid() == -1) {
    eio_unix_fork_error(errors, "setsid", strerror(errno));
    _exit(1);
  }
}

CAMLprim value concurrently_fork_action_setsid(value v_unit) {
  (void) v_unit;

  return val_fork_fn(concurrently_action_setsid);
}
