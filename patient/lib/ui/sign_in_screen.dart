/// AUTH-02 — sign-in.
///
/// Shares its chrome with [RegisterScreen] through `auth_scaffold.dart`; the two screens are the
/// same page with different fields and must not drift into two designs.
///
/// Colours come entirely from [TeraColors]. The failed-sign-in panel uses the system-flag
/// treatment (the plum rule on neutral100) rather than red — red is absent from the palette by
/// design, and a rejected sign-in is a system state, not a physiological one.
///
/// **Signing in navigates.** It used to authenticate and then leave the patient on the sign-in
/// screen, because nothing was listening for the transition: [AuthController] notifies on
/// sign-*out* and the app returns to login, but the successful direction had no counterpart. The
/// destination is not decided here — it comes from [TeraFlow.resumeRouteAfterAuth], which is
/// AUTH-00's table: device check if this handset has never been probed, the unfinished onboarding
/// step if setup is incomplete, otherwise Home.
library;

import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'auth_scaffold.dart';
import 'tokens.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.flow});

  final TeraFlow flow;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A session that ended elsewhere — an unrecoverable refresh, say — leaves its explanation on
    // the controller. Showing it here is the only place the patient will ever see it.
    _error = widget.flow.auth.error;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    final signedIn = await widget.flow.auth.signIn(
      username: _email.text.trim(),
      password: _password.text,
    );
    if (!mounted) return;

    if (!signedIn) {
      final message = widget.flow.auth.error ?? 'Sign-in failed. Please try again.';
      setState(() {
        _busy = false;
        _error = message;
      });
      showAuthError(context, message);
      return;
    }

    final next = await widget.flow.resumeRouteAfterAuth();
    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil(next, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: AuthScaffold(
          title: 'Selamat Datang',
          subtitle: 'Masuk untuk melanjutkan catatan tekanan darah Anda.',
          footer: AuthSwitchLink(
            prompt: 'Belum punya akun?',
            action: 'Register',
            onPressed: _busy ? null : () => Navigator.of(context).pushNamed(Routes.register),
          ),
          children: [
            AuthField(
              id: 'email',
              controller: _email,
              label: 'Email',
              hint: 'cth: nama@email.com',
              icon: Icons.mail_outline,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              validator: AuthValidators.email,
            ),
            const SizedBox(height: TeraSpacing.md),

            AuthField(
              id: 'password',
              controller: _password,
              label: 'Kata Sandi',
              hint: 'Masukkan kata sandimu',
              icon: Icons.lock_outline,
              enabled: !_busy,
              obscureText: !_showPassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              // Not the sign-up rules: an account created before the minimum changed still has
              // to be able to get in.
              validator: AuthValidators.existingPassword,
              onSubmitted: (_) => _submit(),
              suffix: PasswordVisibilityToggle(
                visible: _showPassword,
                onPressed: _busy ? null : () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            const SizedBox(height: TeraSpacing.lg),

            if (error != null) ...[
              AuthErrorPanel(message: error),
              const SizedBox(height: TeraSpacing.lg),
            ],

            AuthSubmitButton(label: 'Login', busy: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
