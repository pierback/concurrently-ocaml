#ifndef _WIN32

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

struct spawn_error {
  int error;
  char operation[32];
};

static int file_descr_val(value v_fd) { return Int_val(v_fd); }

static void close_if_valid(int fd) {
  if (fd >= 0) {
    close(fd);
  }
}

static void free_spawn_inputs(char *executable, char **argv, char **env,
                              char *cwd) {
  if (executable != NULL) {
    caml_stat_free(executable);
  }
  if (argv != NULL) {
    caml_unix_cstringvect_free(argv);
  }
  if (env != NULL) {
    caml_unix_cstringvect_free(env);
  }
  if (cwd != NULL) {
    caml_stat_free(cwd);
  }
}

static void waitpid_ignored(pid_t pid) {
  while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {
  }
}

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags == -1) {
    return -1;
  }

  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int make_cloexec_pipe(int fds[2]) {
  if (pipe(fds) == -1) {
    return -1;
  }
  if (set_cloexec(fds[0]) == -1 || set_cloexec(fds[1]) == -1) {
    int saved_errno = errno;
    close_if_valid(fds[0]);
    close_if_valid(fds[1]);
    errno = saved_errno;
    return -1;
  }

  return 0;
}

static void child_write_error(int fd, const char *operation, int error) {
  struct spawn_error message;

  memset(&message, 0, sizeof(message));
  message.error = error;
  strncpy(message.operation, operation, sizeof(message.operation) - 1);
  (void)write(fd, &message, sizeof(message));
}

static void child_fail(int fd, const char *operation) {
  child_write_error(fd, operation, errno);
  _exit(127);
}

static void child_dup2(int source, int target, int error_fd) {
  if (source == target) {
    int flags = fcntl(target, F_GETFD);
    if (flags == -1) {
      child_fail(error_fd, "fcntl");
    }
    if (fcntl(target, F_SETFD, flags & ~FD_CLOEXEC) == -1) {
      child_fail(error_fd, "fcntl");
    }
    return;
  }

  if (dup2(source, target) == -1) {
    child_fail(error_fd, "dup2");
  }
}

static void child_close_after_dup(int fd) {
  if (fd != STDIN_FILENO && fd != STDOUT_FILENO && fd != STDERR_FILENO) {
    close_if_valid(fd);
  }
}

static void child_set_blocking(int fd, int error_fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags == -1) {
    child_fail(error_fd, "fcntl");
  }
  if (fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == -1) {
    child_fail(error_fd, "fcntl");
  }
}

static int read_spawn_error(int fd, struct spawn_error *message) {
  char *cursor = (char *)message;
  size_t remaining = sizeof(*message);
  ssize_t bytes_read;

  memset(message, 0, sizeof(*message));
  while (remaining > 0) {
    bytes_read = read(fd, cursor, remaining);
    if (bytes_read == 0) {
      return 0;
    }
    if (bytes_read == -1) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    cursor += bytes_read;
    remaining -= (size_t)bytes_read;
  }

  return 1;
}

static pid_t spawn_process(value v_executable, value v_argv, value v_cwd,
                           value v_env, value v_stdin, value v_stdout,
                           value v_stderr) {
  char *executable = NULL;
  char **argv = NULL;
  char **env = NULL;
  char *cwd = NULL;
  int stdin_fd = file_descr_val(v_stdin);
  int stdout_fd = file_descr_val(v_stdout);
  int stderr_fd = file_descr_val(v_stderr);
  int errors[2] = {-1, -1};
  pid_t pid = -1;
  struct spawn_error child_error;

  executable = caml_stat_strdup(String_val(v_executable));
  argv = caml_unix_cstringvect(v_argv, "spawn");
  env = caml_unix_cstringvect(v_env, "spawn");
  if (Is_some(v_cwd)) {
    cwd = caml_stat_strdup(String_val(Field(v_cwd, 0)));
  }

  if (make_cloexec_pipe(errors) == -1) {
    free_spawn_inputs(executable, argv, env, cwd);
    caml_uerror("pipe", Nothing);
  }

  pid = fork();
  if (pid == -1) {
    int saved_errno = errno;
    close_if_valid(errors[0]);
    close_if_valid(errors[1]);
    free_spawn_inputs(executable, argv, env, cwd);
    errno = saved_errno;
    caml_uerror("fork", Nothing);
  }

  if (pid == 0) {
    close_if_valid(errors[0]);
    if (setsid() == -1) {
      child_fail(errors[1], "setsid");
    }
    if (cwd != NULL && chdir(cwd) == -1) {
      child_fail(errors[1], "chdir");
    }
    child_dup2(stdin_fd, STDIN_FILENO, errors[1]);
    child_dup2(stdout_fd, STDOUT_FILENO, errors[1]);
    child_dup2(stderr_fd, STDERR_FILENO, errors[1]);
    child_set_blocking(STDIN_FILENO, errors[1]);
    child_set_blocking(STDOUT_FILENO, errors[1]);
    child_set_blocking(STDERR_FILENO, errors[1]);
    child_close_after_dup(stdin_fd);
    child_close_after_dup(stdout_fd);
    child_close_after_dup(stderr_fd);
    execve(executable, argv, env);
    child_fail(errors[1], "execve");
  }

  close_if_valid(errors[1]);
  switch (read_spawn_error(errors[0], &child_error)) {
  case -1: {
    int saved_errno = errno;
    kill(pid, SIGKILL);
    waitpid_ignored(pid);
    close_if_valid(errors[0]);
    free_spawn_inputs(executable, argv, env, cwd);
    errno = saved_errno;
    caml_uerror("read", Nothing);
  }
  case 0:
    close_if_valid(errors[0]);
    break;
  default:
    kill(pid, SIGKILL);
    waitpid_ignored(pid);
    close_if_valid(errors[0]);
    free_spawn_inputs(executable, argv, env, cwd);
    errno = child_error.error;
    caml_uerror(child_error.operation, Nothing);
  }

  free_spawn_inputs(executable, argv, env, cwd);

  return pid;
}

static value spawn_process_impl(value v_executable, value v_argv, value v_cwd,
                                value v_env, value v_stdin, value v_stdout,
                                value v_stderr) {
  CAMLparam5(v_executable, v_argv, v_cwd, v_env, v_stdin);
  CAMLxparam2(v_stdout, v_stderr);
  pid_t pid = spawn_process(v_executable, v_argv, v_cwd, v_env, v_stdin,
                            v_stdout, v_stderr);
  CAMLreturn(Val_int(pid));
}

CAMLprim value concurrently_posix_spawn_bytecode(value *argv, int argn) {
  (void)argn;
  return spawn_process_impl(argv[0], argv[1], argv[2], argv[3], argv[4],
                            argv[5], argv[6]);
}

CAMLprim value concurrently_posix_spawn(value v_executable, value v_argv,
                                        value v_cwd, value v_env,
                                        value v_stdin, value v_stdout,
                                        value v_stderr) {
  return spawn_process_impl(v_executable, v_argv, v_cwd, v_env, v_stdin,
                            v_stdout, v_stderr);
}

#endif
