import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../routing/check_payload.dart';
import '../routing/check_session.dart';
import 'tokens.dart';

class WalkthroughScreen extends StatefulWidget {
  const WalkthroughScreen({
    super.key,
    required this.session,
    required this.payload,
  });

  final CheckSession session;
  final CheckPayload payload;

  @override
  State<WalkthroughScreen> createState() => _WalkthroughScreenState();
}

class _WalkthroughScreenState extends State<WalkthroughScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < 3) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      TeraFlow.advance(
        context,
        CheckFlow.afterWalkthroughStep(widget.session, 4),
        payload: widget.payload,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: const [
                  _WalkthroughStep(
                    title: 'Sit comfortably',
                    subtitle:
                        'Keep your feet flat on the floor and your back supported.',
                    icon: Icons.chair_alt_outlined,
                  ),
                  _WalkthroughStep(
                    title: 'Phone on chest',
                    subtitle:
                        'Hold your phone flat against the center of your chest.',
                    icon: Icons.phone_android_outlined,
                  ),
                  _WalkthroughStep(
                    title: 'Cover rear camera',
                    subtitle:
                        'Make sure your finger completely covers the back camera lens.',
                    icon: Icons.camera_rear_outlined,
                  ),
                  _WalkthroughStep(
                    title: 'Relax',
                    subtitle:
                        'Breathe normally and avoid speaking during the scan.',
                    icon: Icons.self_improvement_outlined,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (index) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        height: 8,
                        width: _currentPage == index ? 24 : 8,
                        decoration: BoxDecoration(
                          color: _currentPage == index
                              ? TeraColors.brand
                              : TeraColors.neutral300,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                  FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      backgroundColor: TeraColors.ink,
                      foregroundColor: TeraColors.paper,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(TeraRadius.button),
                      ),
                    ),
                    child: Text(
                      _currentPage == 3 ? 'Start Check' : 'Next',
                      style: const TextStyle(
                        fontSize: TeraText.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalkthroughStep extends StatelessWidget {
  const _WalkthroughStep({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(TeraSpacing.xxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(TeraSpacing.xl),
            decoration: const BoxDecoration(
              color: TeraColors.page,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 64, color: TeraColors.brand),
          ),
          const SizedBox(height: TeraSpacing.xxl),
          Text(
            title,
            style: const TextStyle(
              fontSize: TeraText.section,
              fontWeight: FontWeight.w700,
              color: TeraColors.ink,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: TeraSpacing.md),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.neutral700,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
