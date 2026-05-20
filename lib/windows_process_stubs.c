#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/osdeps.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

static void windows_uerror(const char *operation) {
  caml_win32_maperr(GetLastError());
  caml_uerror(operation, Nothing);
}

static void close_if_valid(HANDLE handle) {
  if (handle != NULL && handle != INVALID_HANDLE_VALUE) {
    CloseHandle(handle);
  }
}

static BOOL duplicate_inheritable(HANDLE source, HANDLE *duplicate) {
  HANDLE self = GetCurrentProcess();
  return DuplicateHandle(self, source, self, duplicate, 0, TRUE,
                         DUPLICATE_SAME_ACCESS);
}

static wchar_t *environment_block(value v_env) {
  mlsize_t env_count = Wosize_val(v_env);
  wchar_t **entries = caml_stat_alloc(sizeof(wchar_t *) * env_count);
  size_t character_count = 1;
  mlsize_t index;

  for (index = 0; index < env_count; index++) {
    entries[index] = caml_stat_strdup_to_utf16(String_val(Field(v_env, index)));
    character_count += wcslen(entries[index]) + 1;
  }

  wchar_t *block = caml_stat_alloc(sizeof(wchar_t) * character_count);
  wchar_t *cursor = block;
  for (index = 0; index < env_count; index++) {
    size_t length = wcslen(entries[index]);
    memcpy(cursor, entries[index], sizeof(wchar_t) * length);
    cursor += length;
    *cursor++ = L'\0';
    caml_stat_free(entries[index]);
  }
  *cursor = L'\0';
  caml_stat_free(entries);
  return block;
}

static value create_process_impl(value v_application, value v_command_line,
                                 value v_cwd, value v_env, value v_stdin,
                                 value v_stdout, value v_stderr) {
  CAMLparam5(v_application, v_command_line, v_cwd, v_env, v_stdin);
  CAMLxparam2(v_stdout, v_stderr);
  CAMLlocal1(result);

  wchar_t *application = NULL;
  wchar_t *command_line = NULL;
  wchar_t *cwd = NULL;
  wchar_t *env = NULL;
  HANDLE child_stdin = NULL;
  HANDLE child_stdout = NULL;
  HANDLE child_stderr = NULL;
  HANDLE job = NULL;
  PROCESS_INFORMATION process_info;
  STARTUPINFOW startup_info;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits;
  DWORD error = ERROR_SUCCESS;
  DWORD flags = CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED;
  const char *failed_operation = NULL;

  ZeroMemory(&process_info, sizeof(process_info));
  ZeroMemory(&startup_info, sizeof(startup_info));
  ZeroMemory(&job_limits, sizeof(job_limits));

  application = caml_stat_strdup_to_utf16(String_val(v_application));
  command_line = caml_stat_strdup_to_utf16(String_val(v_command_line));
  if (Is_some(v_cwd)) {
    cwd = caml_stat_strdup_to_utf16(String_val(Field(v_cwd, 0)));
  }
  env = environment_block(v_env);

  if (!duplicate_inheritable(Handle_val(v_stdin), &child_stdin)) {
    failed_operation = "DuplicateHandle";
    error = GetLastError();
    goto fail;
  }
  if (!duplicate_inheritable(Handle_val(v_stdout), &child_stdout)) {
    failed_operation = "DuplicateHandle";
    error = GetLastError();
    goto fail;
  }
  if (!duplicate_inheritable(Handle_val(v_stderr), &child_stderr)) {
    failed_operation = "DuplicateHandle";
    error = GetLastError();
    goto fail;
  }

  job = CreateJobObjectW(NULL, NULL);
  if (job == NULL) {
    failed_operation = "CreateJobObjectW";
    error = GetLastError();
    goto fail;
  }
  job_limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                               &job_limits, sizeof(job_limits))) {
    failed_operation = "SetInformationJobObject";
    error = GetLastError();
    goto fail;
  }

  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdInput = child_stdin;
  startup_info.hStdOutput = child_stdout;
  startup_info.hStdError = child_stderr;

  if (!CreateProcessW(application, command_line, NULL, NULL, TRUE, flags, env,
                      cwd, &startup_info, &process_info)) {
    failed_operation = "CreateProcessW";
    error = GetLastError();
    goto fail;
  }

  close_if_valid(child_stdin);
  close_if_valid(child_stdout);
  close_if_valid(child_stderr);
  child_stdin = NULL;
  child_stdout = NULL;
  child_stderr = NULL;

  if (!AssignProcessToJobObject(job, process_info.hProcess)) {
    error = GetLastError();
    TerminateProcess(process_info.hProcess, 1);
    failed_operation = "AssignProcessToJobObject";
    goto fail;
  }

  if (ResumeThread(process_info.hThread) == (DWORD)-1) {
    error = GetLastError();
    TerminateJobObject(job, 1);
    failed_operation = "ResumeThread";
    goto fail;
  }
  close_if_valid(process_info.hThread);
  process_info.hThread = NULL;

  caml_stat_free(application);
  caml_stat_free(command_line);
  if (cwd != NULL) {
    caml_stat_free(cwd);
  }
  caml_stat_free(env);

  result = caml_alloc_tuple(3);
  Store_field(result, 0, Val_int(process_info.dwProcessId));
  Store_field(result, 1, caml_copy_nativeint((intnat)process_info.hProcess));
  Store_field(result, 2, caml_copy_nativeint((intnat)job));
  CAMLreturn(result);

fail:
  close_if_valid(child_stdin);
  close_if_valid(child_stdout);
  close_if_valid(child_stderr);
  close_if_valid(process_info.hThread);
  close_if_valid(process_info.hProcess);
  close_if_valid(job);
  if (application != NULL) {
    caml_stat_free(application);
  }
  if (command_line != NULL) {
    caml_stat_free(command_line);
  }
  if (cwd != NULL) {
    caml_stat_free(cwd);
  }
  if (env != NULL) {
    caml_stat_free(env);
  }
  SetLastError(error);
  windows_uerror(failed_operation);
}

CAMLprim value concurrently_windows_create_process_bytecode(value *argv,
                                                            int argn) {
  (void)argn;
  return create_process_impl(argv[0], argv[1], argv[2], argv[3], argv[4],
                             argv[5], argv[6]);
}

CAMLprim value concurrently_windows_create_process(value v_application,
                                                   value v_command_line,
                                                   value v_cwd, value v_env,
                                                   value v_stdin,
                                                   value v_stdout,
                                                   value v_stderr) {
  return create_process_impl(v_application, v_command_line, v_cwd, v_env,
                             v_stdin, v_stdout, v_stderr);
}

CAMLprim value concurrently_windows_await(value v_process) {
  HANDLE process = (HANDLE)Nativeint_val(v_process);
  DWORD exit_code = 1;
  DWORD wait_result;
  DWORD error = ERROR_SUCCESS;
  BOOL got_exit_code = FALSE;

  caml_release_runtime_system();
  wait_result = WaitForSingleObject(process, INFINITE);
  if (wait_result == WAIT_OBJECT_0) {
    got_exit_code = GetExitCodeProcess(process, &exit_code);
    if (!got_exit_code) {
      error = GetLastError();
    }
  } else {
    error = GetLastError();
  }
  caml_acquire_runtime_system();

  if (wait_result != WAIT_OBJECT_0) {
    SetLastError(error);
    windows_uerror("WaitForSingleObject");
  }
  if (!got_exit_code) {
    SetLastError(error);
    windows_uerror("GetExitCodeProcess");
  }
  return Val_int(exit_code);
}

CAMLprim value concurrently_windows_terminate_job(value v_job,
                                                  value v_exit_code) {
  HANDLE job = (HANDLE)Nativeint_val(v_job);
  if (!TerminateJobObject(job, Int_val(v_exit_code))) {
    windows_uerror("TerminateJobObject");
  }
  return Val_unit;
}

CAMLprim value concurrently_windows_close_handle(value v_handle) {
  HANDLE handle = (HANDLE)Nativeint_val(v_handle);
  if (handle != NULL && handle != INVALID_HANDLE_VALUE && !CloseHandle(handle)) {
    windows_uerror("CloseHandle");
  }
  return Val_unit;
}

#endif
