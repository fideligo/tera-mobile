/// Sign-in.
///
/// Colours come entirely from [TeraColors]; nothing new is introduced. The failed-sign-in
/// panel uses the system-flag treatment (ink on ink100, 12.19:1) rather than red — red is
/// absent from the palette by design, and a rejected sign-in is a system state.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'tokens.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    await widget.auth.signIn(username: _username.text.trim(), password: _password.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.auth.error;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(TeraSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Tera',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: TeraColors.ink,
                      ),
                    ),
                    const SizedBox(height: TeraSpacing.xs),
                    const Text(
                      'Monitoring between clinic visits. Tera does not replace a cuff and '
                      'does not diagnose.',
                      style: TextStyle(
                        color: TeraColors.neutral700,
                        fontSize: TeraText.body,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: TeraSpacing.xl),

                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(labelText: 'Username'),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter your username.' : null,
                    ),
                    const SizedBox(height: TeraSpacing.md),
                    TextFormField(
                      controller: _password,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password.' : null,
                    ),

                    if (error != null) ...[
                      const SizedBox(height: TeraSpacing.md),
                      Container(
                        decoration: systemFlagDecoration(),
                        padding: const EdgeInsets.all(TeraSpacing.md),
                        child: Text(
                          error,
                          style: const TextStyle(color: TeraColors.ink, height: 1.4),
                        ),
                      ),
                    ],

                    const SizedBox(height: TeraSpacing.lg),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy ? 'Signing in…' : 'Sign in'),
                    ),
                    const SizedBox(height: TeraSpacing.lg),
                    const Divider(),
                    const SizedBox(height: TeraSpacing.md),
                    const Text(
                      'Accounts are created by your clinic. There is no self-registration.',
                      style: TextStyle(
                        fontSize: TeraText.small,
                        height: 1.5,
                        color: TeraColors.neutral700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
