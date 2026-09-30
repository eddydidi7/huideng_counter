import 'dart:async';
import 'dart:io';

/// Group administration / speaking rules (migration 202609250072).
const groupAdminMessages = {
  'GROUP_MUTED': '你已被禁言，暂时不能在本群发言（仍可查看消息）',
  'GROUP_ALL_MUTED': '本群已开启全员禁言，只有群主和管理员可以发言',
  'GROUP_READ_ANNOUNCEMENT': '请先阅读群公告并点击“我已阅读”后再发言',
  'GROUP_SLOW_DOWN': '发送太快了，请稍等几秒再发',
  'GROUP_DUPLICATE': '请不要重复发送相同内容',
  'GROUP_TOO_MANY_IMAGES': '短时间内发送图片过多，请稍后再发',
  'GROUP_TOO_MANY_LINKS': '短时间内发送链接过多，请稍后再发',
  'GROUP_TEMP_LIMITED': '发言过于频繁，已临时限制发送，几分钟后自动恢复',
  'GROUP_ADMIN_LIMIT': '每个群最多设置 10 位管理员',
  'GROUP_OWNER_REQUIRED': '只有群主可以进行此操作',
  'GROUP_BANNED': '已被加入本群黑名单，无法加入',
  'GROUP_JOINS_PAUSED': '本群已暂停新成员加入',
  'GROUP_INVITE_ONLY': '本群仅限成员邀请加入',
  'GROUP_APPROVAL_REQUIRED': '本群需要管理员审核，请提交入群申请',
  'GROUP_APPROVAL_NOT_NEEDED': '本群无需审核，可直接加入',
  'GROUP_QR_DISABLED': '本群已关闭二维码加入',
  'GROUP_NICKNAME_DISABLED': '群主未允许成员修改群昵称',
  'GROUP_PIN_LIMIT': '置顶消息已达上限（50 条）',
  'REQUEST_UNAVAILABLE': '该申请已被处理',
  'QR_EXPIRED': '二维码已过期，请让群主刷新',
  'CHAT_INVALID_AVATAR': '群头像上传失败，请重新选择图片',
  'GROUP_FRIEND_ADD_DISABLED': '群主已关闭“允许群成员互加好友”，暂时无法通过本群添加',
  'CHAT_MENTION_LIMIT': '一条消息最多只能@50人',
  'CHAT_INVALID_MENTION': '所@的成员已不在本群，请重新选择',
  'CHAT_MENTION_ALL_DENIED': '只有群主和管理员可以使用@所有人',
};

String? groupAdminMessage(Object error) {
  final text = error.toString();
  for (final item in groupAdminMessages.entries) {
    if (text.contains(item.key)) return item.value;
  }
  return null;
}

String groupOperationError(Object error) {
  final admin = groupAdminMessage(error);
  if (admin != null) return admin;
  final text = error.toString();
  for (final item in {
    'CHAT_GROUP_SIZE': '群成员已达到人数上限',
    'CHAT_MANAGER_REQUIRED': '你没有管理此群的权限',
    'CHAT_NOT_MEMBER': '你已不在此群，无法添加成员',
    'CHAT_INVALID_USER': '所选用户不存在或账号不可用',
    'CHAT_NO_NEW_MEMBERS': '请选择至少一位新的群成员',
    'CHAT_INVALID_NAME': '群名称需为 1～80 个字符',
    'CHAT_BLOCKED': '你与所选用户存在拉黑关系，无法添加',
    'CHAT_LOGIN_REQUIRED': '登录状态已失效，请重新登录',
    'CHAT_RATE_LIMIT': '操作过于频繁，请稍后再试',
    'PGRST202': '服务器尚未更新群管理功能',
    '42501': '服务器拒绝操作，请核对群权限',
    '23503': '所选用户或群已不存在，请刷新后重试',
    '23505': '成员已存在，请刷新群成员列表',
  }.entries) {
    if (text.contains(item.key)) return item.value;
  }
  if (error is SocketException ||
      error is TimeoutException ||
      text.contains('ClientException')) {
    return '网络连接失败，请重试';
  }
  return '操作失败，请稍后重试';
}
