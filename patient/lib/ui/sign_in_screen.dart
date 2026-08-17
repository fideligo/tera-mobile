/// AUTH-01 — Login screen (PM spec section 5).
///
/// Matches the Figma `Login.png` design:
///
///   - "Selamat Datang" centered title
///   - Form card on neutral page ground with Email + Kata Sandi fields
///   - Navy "Login" primary button
///   - "Atau lanjut dengan" divider + Google outlined button
///   - "Belum punya akun? Register" footer
///
/// Wired directly to [AuthController.signIn] — no stubs.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../routing/routes.dart';
import 'tokens.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);

    final success = await widget.auth.signIn(
      username: _email.text.trim(),
      password: _password.text,
    );

    if (mounted) {
      setState(() => _busy = false);
      if (success) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(Routes.splash, (r) => false);
      }
    }
  }

  /// Skip sign-in entirely. Home and the check flow read [AuthController.canUseApp], which a
  /// guest satisfies; History and Profile gate themselves separately, at the tap, because
  /// nothing backing either can work without a token to send.
  void _continueAsGuest() {
    widget.auth.continueAsGuest();
    Navigator.of(context).pushNamedAndRemoveUntil(Routes.home, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.auth.error;

    return Scaffold(
      backgroundColor: TeraColors.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: TeraSpacing.xl),

                  // ── Logo ──
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(TeraRadius.card),
                      child: Image.asset(
                        'assets/logo.jpeg',
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.lg),

                  // ── Title ──
                  const Text(
                    'Selamat Datang',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: TeraColors.ink,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.sm),
                  const Text(
                    'Pantau tekanan darahmu dengan mudah',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: TeraText.body,
                      color: TeraColors.neutral700,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.xxl),

                  // ── Form card ──
                  Container(
                    padding: const EdgeInsets.all(TeraSpacing.lg),
                    decoration: BoxDecoration(
                      color: TeraColors.paper,
                      borderRadius: BorderRadius.circular(TeraRadius.card),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Email label
                          RichText(
                            text: const TextSpan(
                              text: 'Email ',
                              style: TextStyle(
                                fontSize: TeraText.body,
                                fontWeight: FontWeight.w600,
                                color: TeraColors.ink,
                              ),
                              children: [
                                TextSpan(
                                  text: '*',
                                  style: TextStyle(color: TeraColors.plum),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: TeraSpacing.sm),
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            style: const TextStyle(
                              fontSize: TeraText.body,
                              color: TeraColors.ink,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'cth: nama@email.com',
                              hintStyle: TextStyle(
                                color: TeraColors.neutral500,
                              ),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: TeraSpacing.md,
                                vertical: 14,
                              ),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Masukkan email kamu.'
                                : null,
                          ),
                          const SizedBox(height: TeraSpacing.lg),

                          // Password label
                          RichText(
                            text: const TextSpan(
                              text: 'Kata Sandi ',
                              style: TextStyle(
                                fontSize: TeraText.body,
                                fontWeight: FontWeight.w600,
                                color: TeraColors.ink,
                              ),
                              children: [
                                TextSpan(
                                  text: '*',
                                  style: TextStyle(color: TeraColors.plum),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: TeraSpacing.sm),
                          TextFormField(
                            controller: _password,
                            obscureText: _obscure,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            style: const TextStyle(
                              fontSize: TeraText.body,
                              color: TeraColors.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Masukkan kata sandimu',
                              hintStyle: const TextStyle(
                                color: TeraColors.neutral500,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: TeraSpacing.md,
                                vertical: 14,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: TeraColors.neutral500,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Masukkan kata sandi.'
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Error ──
                  if (error != null) ...[
                    const SizedBox(height: TeraSpacing.md),
                    Container(
                      decoration: systemFlagDecoration(),
                      padding: const EdgeInsets.all(TeraSpacing.md),
                      child: Text(
                        error,
                        style: const TextStyle(
                          color: TeraColors.ink,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: TeraSpacing.lg),

                  // ── Login button ──
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: TeraColors.ink,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            TeraRadius.button,
                          ),
                        ),
                        textStyle: const TextStyle(
                          fontSize: TeraText.body,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Login'),
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.lg),

                  // ── Divider ──
                  //
                  // The Google button that sat below this was removed: it had `onPressed: () {}`,
                  // an empty callback, so it looked like a working sign-in route and silently did
                  // nothing. On an auth screen that is worse than absent — someone tries it,
                  // nothing happens, and they have no idea whether they are signed in.
                  Row(
                    children: [
                      Expanded(child: Divider(color: TeraColors.neutral300)),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: TeraSpacing.md,
                        ),
                        child: Text(
                          'or',
                          style: TextStyle(
                            fontSize: TeraText.small,
                            color: TeraColors.neutral700,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: TeraColors.neutral300)),
                    ],
                  ),
                  const SizedBox(height: TeraSpacing.lg),

                  // ── Guest ──
                  SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _continueAsGuest,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TeraColors.brand,
                        side: const BorderSide(color: TeraColors.brand),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            TeraRadius.button,
                          ),
                        ),
                        textStyle: const TextStyle(
                          fontSize: TeraText.body,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Continue as guest'),
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.sm),
                  const Text(
                    'A guest check runs entirely on this phone. You get your heart rate and '
                    'signal quality, but nothing is saved and no blood-pressure trend is '
                    'produced — a trend needs an account and a cuff reading to compare against.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: TeraText.small,
                      color: TeraColors.neutral700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.lg),

                  // ── Register footer ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Belum punya akun? ',
                        style: TextStyle(
                          fontSize: TeraText.small,
                          color: TeraColors.neutral700,
                        ),
                      ),
                      GestureDetector(
                        onTap: () =>
                            Navigator.of(context).pushNamed(Routes.register),
                        child: const Text(
                          'Register',
                          style: TextStyle(
                            fontSize: TeraText.small,
                            fontWeight: FontWeight.w600,
                            color: TeraColors.ink,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
