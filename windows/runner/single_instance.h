#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>
#include <vector>

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
bool NotifyExistingInstance(const std::vector<std::string>& arguments = {});
bool ReadQuickSendCopyData(const COPYDATASTRUCT* copy_data,
                           std::vector<std::string>* arguments);

#endif  // RUNNER_SINGLE_INSTANCE_H_
