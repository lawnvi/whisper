#ifndef RUNNER_INPUT_SERVICE_UPDATE_H_
#define RUNNER_INPUT_SERVICE_UPDATE_H_

#include <windows.h>

#include <string>

namespace whisper_input_service {

// Run by the agent, as LocalSystem, for kCommandUpdate: takes the files the
// manifest beside [client_process]'s executable names, when it is signed,
// newer than this build and every hash matches, puts them in place of the
// installed ones and has the service restarted on them. Returns a Status.
DWORD UpdateFromClient(DWORD client_process);

// Called as the service starts: deletes what an update or an uninstall had
// to leave behind because it was still running.
void RemoveLeftovers();

// Deletes [path], or, while it is still running (the installed copy removing
// itself), moves it out of the way under a name of its own and deletes it at
// the next restart.
void RemoveFileNowOrLater(const std::wstring& path);

}  // namespace whisper_input_service

#endif  // RUNNER_INPUT_SERVICE_UPDATE_H_
