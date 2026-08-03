class CommunityMessage {
  final String id;
  final String userId;
  final String displayName;
  final String avatarUrl;
  final String text;
  final String createdAt;
  final String attachmentType;
  final String attachmentPath;

  const CommunityMessage({
    required this.id,
    required this.userId,
    required this.displayName,
    required this.text,
    this.avatarUrl = '',
    this.createdAt = '',
    this.attachmentType = '',
    this.attachmentPath = '',
  });

  factory CommunityMessage.fromJson(Map<String, dynamic> json) {
    return CommunityMessage(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? json['user_id']?.toString() ?? '',
      displayName:
          json['displayName']?.toString() ??
          json['display_name']?.toString() ??
          'Ẩn danh',
      avatarUrl:
          json['avatarUrl']?.toString() ?? json['avatar_url']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      createdAt:
          json['createdAt']?.toString() ?? json['created_at']?.toString() ?? '',
      attachmentType:
          json['attachmentType']?.toString() ??
          json['attachment_type']?.toString() ??
          '',
      attachmentPath:
          json['attachmentPath']?.toString() ??
          json['attachment_path']?.toString() ??
          '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'displayName': displayName,
      'avatarUrl': avatarUrl,
      'text': text,
      'createdAt': createdAt,
      'attachmentType': attachmentType,
      'attachmentPath': attachmentPath,
    };
  }
}
