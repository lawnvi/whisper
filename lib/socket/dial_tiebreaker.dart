/// 同 peer 互拨(双方同时向对方拨号)的确定性裁决。
///
/// 双方各自独立计算,结论互补:uid 字典序小(含相等)的一方保留自己的
/// 出站拨号并关闭对方拨入,大的一方放弃出站、接受对方拨入。
/// 恰好一条连接存活,零抖动;相等 uid(自连)一律关闭拨入。
enum SimultaneousDialDecision { keepOutgoing, acceptIncoming }

SimultaneousDialDecision resolveSimultaneousDial({
  required String localUid,
  required String remoteUid,
}) {
  return localUid.compareTo(remoteUid) <= 0
      ? SimultaneousDialDecision.keepOutgoing
      : SimultaneousDialDecision.acceptIncoming;
}
