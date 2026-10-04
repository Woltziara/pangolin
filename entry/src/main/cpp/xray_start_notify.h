#ifndef TONGDAO_XRAY_START_NOTIFY_H
#define TONGDAO_XRAY_START_NOTIFY_H

#include <atomic>

enum class XrayTsfnFate {
  Ok = 0,
  ClosingDrop = 1,
  Retry = 2
};

enum class XrayNotifyAction {
  KeepRetrying = 0,
  Dispatched = 1,
  ClosingDrop = 2,
  Abandon = 3,
  AlreadySettled = 4
};

inline XrayTsfnFate XrayClassifyTsfnStatus(int status, int napiOk, int napiClosing)
{
  if (status == napiOk) {
    return XrayTsfnFate::Ok;
  }
  if (status == napiClosing) {
    return XrayTsfnFate::ClosingDrop;
  }
  return XrayTsfnFate::Retry;
}

inline bool XrayTakeWorkerReap(std::atomic_bool& owned)
{
  return owned.exchange(false);
}

inline bool XraySpendNotifyRetry(int& left)
{
  if (left <= 0) {
    return false;
  }
  left -= 1;
  return true;
}

inline XrayNotifyAction XrayAdvanceNotify(int& retriesLeft, XrayTsfnFate fate)
{
  if (fate == XrayTsfnFate::Ok) {
    return XrayNotifyAction::Dispatched;
  }
  if (fate == XrayTsfnFate::ClosingDrop) {
    return XrayNotifyAction::ClosingDrop;
  }
  if (retriesLeft <= 1) {
    retriesLeft = 0;
    return XrayNotifyAction::Abandon;
  }
  retriesLeft -= 1;
  return XrayNotifyAction::KeepRetrying;
}

inline bool XrayNotifyReleaseTsfn(XrayNotifyAction action)
{
  return action == XrayNotifyAction::Abandon;
}

constexpr int XRAY_NOTIFY_RETRY_LIMIT = 5;

#endif
