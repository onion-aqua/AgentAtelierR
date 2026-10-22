import 'package:flutter/material.dart';

import 'app_localization.dart';

/// Replaces the composer until the startup wake interaction is completed.
class ColdStartWakeButton extends StatelessWidget {
  const ColdStartWakeButton({
    super.key,
    required this.language,
    required this.onPressed,
    this.waking = false,
  });

  final AppLanguage language;
  final VoidCallback onPressed;
  final bool waking;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
    child: SizedBox(
      width: double.infinity,
      child: AnimatedScale(
        scale: waking ? .97 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: TextButton.icon(
          key: const ValueKey('cold-start-wake-button'),
          onPressed: waking ? null : onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 46),
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white70,
            backgroundColor: Colors.white.withValues(alpha: .12),
            side: BorderSide(
              color: Colors.white.withValues(alpha: .28),
              width: 0,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          ),
          icon: Icon(
            waking ? Icons.wb_twilight_rounded : Icons.bedtime_outlined,
            size: 20,
          ),
          label: Text(
            waking
                ? language.text(
                    '莱莎正在醒来…',
                    'Ryza is waking up…',
                    'ライザが目を覚ましています…',
                  )
                : language.text('点击叫醒莱莎', 'Tap to wake Ryza', 'タップしてライザを起こす'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    ),
  );
}
