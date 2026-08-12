/// AUTH-01 — self-registration.
///
/// Three fields, and only two of them leave the handset. `POST /v1/auth/register-patient` takes a
/// login subject and a password; it creates the account, the patient record and the first
/// monitoring episode in one transaction, and it returns tokens, so signing up signs you in.
///
/// **The name is not sent.** The backend generates a pseudonym on purpose and has nowhere to put
/// a real name — putting one there would write an identity into a clinical record that is
/// designed not to hold one. So the name is stored on the handset with the rest of the local PHR
/// and is used to greet the patient on their own phone. See [PhrProfile.displayName].
///
/// On success the patient lands wherever AUTH-00 says a signed-in account with no setup behind it
/// belongs — the device check, in practice. The route is not hard-coded here: it comes from
/// [TeraFlow.beginNewAccount] and [AppFlowState.resumeRoute], so this screen cannot disagree with
/// the splash about where a new account starts.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../capture/phr_profile.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'auth_scaffold.dart';
import 'tokens.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.flow, required this.profileStore});

  final TeraFlow flow;

  /// Injectable, so a widget test does not need a real Keystore. Holds the display name.
  final PhrProfileStore profileStore;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    // Validate before the request, so a short password is a field error under the field rather
    // than a 422 that comes back a second later with nothing pointing at the cause.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    final created = await widget.flow.auth.register(
      subject: _email.text.trim(),
      password: _password.text,
    );
    if (!mounted) return;

    if (!created) {
      final message = widget.flow.auth.error ?? 'Sign-up failed. Please try again.';
      setState(() {
        _busy = false;
        _error = message;
      });
      showAuthError(context, message);
      return;
    }

    // Signed in. What follows is local: a setup state belonging to this account rather than to
    // whoever used the handset before it, and the name to greet them by.
    //
    // Neither may fail the sign-up, and neither may stall it. The account exists on the server by
    // now, so a Keystore that throws or wedges must not leave the patient watching a spinner in
    // front of an account that has already been created — there would be no way on except killing
    // the app, and the second attempt would answer 409. So: bounded, and swallowed.
    //
    // The flow state goes first because it is the one with consequences. The name is a greeting.
    try {
      await Future(() async {
        await widget.flow.beginNewAccount();
        await widget.profileStore.write(PhrProfile(displayName: _name.text.trim()));
      }).timeout(const Duration(seconds: 5));
    } on Object {
      // Nothing useful to say: the next screen is the same either way, and onboarding recomputes
      // its position from whatever did reach disk.
    }
    if (!mounted) return;

    TextInput.finishAutofillContext();
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(widget.flow.state.resumeRoute, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: AuthScaffold(
          title: 'Buat akun',
          subtitle:
              'Tera keeps your blood-pressure record on your phone and in your account. '
              'A cuff reading stays the reference; Tera tracks what changes between them.',
          footer: AuthSwitchLink(
            prompt: 'Sudah punya akun?',
            action: 'Login',
            // Pop rather than push: this screen is reached from sign-in, so going back is going
            // back. Pushing would stack a second sign-in behind it.
            onPressed: _busy
                ? null
                : () {
                    final navigator = Navigator.of(context);
                    if (navigator.canPop()) {
                      navigator.pop();
                    } else {
                      navigator.pushNamedAndRemoveUntil(Routes.login, (route) => false);
                    }
                  },
          ),
          children: [
            AuthField(
              controller: _name,
              label: 'Name',
              hint: 'What should Tera call you?',
              icon: Icons.person_outline,
              enabled: !_busy,
              keyboardType: TextInputType.name,
              autofillHints: const [AutofillHints.name],
              validator: AuthValidators.name,
            ),
            const SizedBox(height: TeraSpacing.md),

            AuthField(
              controller: _email,
              label: 'Email',
              icon: Icons.mail_outline,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              validator: AuthValidators.email,
            ),
            const SizedBox(height: TeraSpacing.md),

            AuthField(
              controller: _password,
              label: 'Password',
              icon: Icons.lock_outline,
              helper: 'At least $minPasswordLength characters.',
              enabled: !_busy,
              obscureText: !_showPassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              validator: AuthValidators.newPassword,
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

            AuthSubmitButton(label: 'Register', busy: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
