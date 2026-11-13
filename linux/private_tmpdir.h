#ifndef RUNNER_PRIVATE_TMPDIR_H_
#define RUNNER_PRIVATE_TMPDIR_H_

// Points TMPDIR at a folder only this user can open, unless it is set
// already. Call before anything reads it (Dart reads it once at start).
void use_private_tmpdir();

#endif  // RUNNER_PRIVATE_TMPDIR_H_
