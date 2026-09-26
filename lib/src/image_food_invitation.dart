/// A current image can be offered as food only when the user's own message
/// explicitly invites the character to eat or taste it. The model still has
/// to inspect the image and confirm that it contains edible food.
bool hasCurrentImageFoodInvitation(
  String message, {
  required bool hasReadableImage,
}) => hasReadableImage && isExplicitImageFoodInvitation(message);

bool isExplicitImageFoodInvitation(String message) {
  final text = message.toLowerCase().replaceAll(
    RegExp(r'“[^”]*”|‘[^’]*’|"[^"]*"'),
    '',
  );
  if (text.trim().isEmpty) return false;

  final sentences = RegExp(r'[^。.!！?？\n；;]+[。.!！?？]?')
      .allMatches(text)
      .map((match) => match.group(0)!.trim());
  for (final sentence in sentences) {
    if (RegExp(
      r'别|不要|不准|不能|禁止|勿|别让|不让|拒绝|don\x27t|do not|never|not to|食べない|食べるな|食べてはいけない',
      caseSensitive: false,
    ).hasMatch(sentence)) {
      continue;
    }
    if (RegExp(
      r'能吃吗|可以吃吗|能不能吃|可不可以吃|是否能吃|好吃吗|什么味道|能尝吗|can (?:you|she) eat|is (?:it|this) edible|吃了吗|吃了嗎|吃过吗|吃過嗎',
      caseSensitive: false,
    ).hasMatch(sentence)) {
      continue;
    }
    if (RegExp(
      r'喜欢吃|喜歡吃|已经吃|已經吃|以前吃|经常吃|經常吃|正在吃|吃过|吃過|吃了|吃過|会吃|會吃|想吃|能吃|可以吃|可能吃|如果|假如|假设|假設|要是|if ',
    ).hasMatch(sentence)) {
      continue;
    }
    final explicitRequest = RegExp(
      r'(?:请|請)[，,:：\s]*(?:莱莎|莱沙|你|妳)?[，,:：\s]*(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)|(?:邀请|邀請|让|讓|给|給|喂|餵)(?:莱莎|莱沙|你|妳)[^。.!！?？\n；;]{0,6}(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)',
    ).hasMatch(sentence);
    final directCommand = RegExp(
      r'(?:莱莎|莱沙|你|妳|来|來|一起)[，,:：\s]*(?:请|請|快|来|來|也|一起)?[，,:：\s]*(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)(?:尝|嚐|这个|這個|这张|這張|这份|這份|这块|這塊|这道|這道|一口|一点|一點|一些|点|點|它|吧|呀|啦|啊|哦|喔)',
    ).hasMatch(sentence);
    final invitationQuestion = RegExp(
      r'(?:莱莎|莱沙|你|妳)[^。.!！?？\n；;]{0,8}(?:要不要|愿不愿意|願不願意)[^。.!！?？\n；;]{0,8}(?:吃|尝|嚐|品尝|品嚐|试吃|試吃)',
    ).hasMatch(sentence);
    final englishRequest = RegExp(
      r'(?:ryza[,:\s]+|please\s+|would you\s+|let\x27s\s+)(?:please\s+)?(?:eat|taste|try|have|take a bite)\s+(?:this|it|some|a bite|the food)',
      caseSensitive: false,
    ).hasMatch(sentence);
    final japaneseRequest = RegExp(
      r'(?:ライザ[^。.!！?？\n；;]{0,12})?(?:食べて|食べよう|味見して)',
    ).hasMatch(sentence);
    final command =
        explicitRequest || directCommand || englishRequest || japaneseRequest;
    if ((sentence.endsWith('?') || sentence.endsWith('？')) &&
        !invitationQuestion &&
        !RegExp(r'请|請|吧|please|would you').hasMatch(sentence)) {
      continue;
    }
    if (command || invitationQuestion) return true;
  }
  return false;
}
