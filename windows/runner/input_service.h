#ifndef RUNNER_INPUT_SERVICE_H_
#define RUNNER_INPUT_SERVICE_H_

#include <optional>

// whisper.exe doubles as the lock screen input service. Returns the exit code
// when the command line asks for one of the service roles, and nothing for an
// ordinary app launch. The service roles must be handled before anything
// touches Flutter: the installed copy runs without it.
std::optional<int> RunInputServiceCommand();

#endif  // RUNNER_INPUT_SERVICE_H_
