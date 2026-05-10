#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

class SingleInstanceLock {
 public:
  SingleInstanceLock();
  ~SingleInstanceLock();

  SingleInstanceLock(const SingleInstanceLock&) = delete;
  SingleInstanceLock& operator=(const SingleInstanceLock&) = delete;

  bool IsPrimary() const;

 private:
  HANDLE mutex_ = nullptr;
  bool is_primary_ = false;
};

UINT GetSingleInstanceWakeMessage();
bool NotifyExistingInstance();

#endif  // RUNNER_SINGLE_INSTANCE_H_
