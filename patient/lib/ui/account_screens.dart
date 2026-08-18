/// The account, as opposed to the record: the password, and closing it.
///
/// Both talk to `/v1/auth`, both require the password again even though the caller already holds a
/// valid token, and both are destructive in a way the clinical screens are not. They live together
/// because the reasoning is the same one twice: a token can be a stolen one, or a session left open
/// on a shared handset, and re-proving the password is what stops possession of a token becoming a
/// permanent takeover.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../capture/phr_profile.dart';
import 'tokens.dart';

// `minPasswordLength` comes from `api_client.dart`, which already mirrors the server's
// `MIN_PASSWORD_LENGTH` for the sign-up form. Declaring a second copy here is how the two forms
// end up disagreeing about the same rule.

/// PROF-09 — change the password.
///
/// The server revokes every refresh token on success, this device's included, so the patient is
/// signed out everywhere. That is deliberate — a password change is what someone does when they
/// think they are compromised, and leaving the other session alive would make it theatre — and it
/// is stated on the screen rather than discovered.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, required this.api, required this.onDone});

  final ApiClient api;

  /// Called after a successful change. The caller decides where that goes; because every session
  /// is now revoked, the honest destination is the sign-in screen.
  final VoidCallback onDone;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    try {
      await widget.api.postJson('/v1/auth/password', {
        'current_password': _current.text,
        'new_password': _next.text,
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 403 is the server's answer to a wrong current password, and it carries a sentence
        // written for a patient. 401 would have signed them out on the way here — the client
        // treats it as a dead session — which is why the endpoint does not use it for this.
        _error = e.statusCode == 403
            ? 'That is not your current password.'
            : e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not change your password. $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: _done ? _successBody() : _formBody(),
      ),
    );
  }

  Widget _successBody() => Padding(
    padding: const EdgeInsets.all(TeraSpacing.lg),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline, size: 64, color: TeraColors.brand),
        const SizedBox(height: TeraSpacing.lg),
        const Text(
          'Your password has been changed',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: TeraText.section,
            fontWeight: FontWeight.w700,
            color: TeraColors.ink,
          ),
        ),
        const SizedBox(height: TeraSpacing.md),
        const Text(
          'Every device signed in to this account has been signed out, including this one. Sign '
          'in again with your new password.',
          textAlign: TextAlign.center,
          style: TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        const SizedBox(height: TeraSpacing.xl),
        FilledButton(
          onPressed: widget.onDone,
          style: FilledButton.styleFrom(
            backgroundColor: TeraColors.ink,
            foregroundColor: TeraColors.paper,
            padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
          ),
          child: const Text('Sign in'),
        ),
      ],
    ),
  );

  Widget _formBody() => SingleChildScrollView(
    padding: const EdgeInsets.all(TeraSpacing.lg),
    child: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(
            controller: _current,
            label: 'Current password',
            validator: (v) => (v == null || v.isEmpty)
                ? 'Enter your current password.'
                : null,
          ),
          const SizedBox(height: TeraSpacing.md),
          _field(
            controller: _next,
            label: 'New password',
            validator: (v) {
              final value = v ?? '';
              if (value.length < minPasswordLength) {
                return 'Use at least $minPasswordLength characters.';
              }
              if (value == _current.text) {
                return 'Choose a password you have not used here before.';
              }
              return null;
            },
          ),
          const SizedBox(height: TeraSpacing.md),
          _field(
            controller: _confirm,
            label: 'Confirm new password',
            // Checked here rather than at the server, which has no second field to compare
            // against and no way to tell a mistyped confirmation from a deliberate one.
            validator: (v) => v == _next.text ? null : 'The two passwords do not match.',
          ),
          if (_error != null) ...[
            const SizedBox(height: TeraSpacing.md),
            Container(
              padding: const EdgeInsets.all(TeraSpacing.md),
              decoration: systemFlagDecoration(),
              child: Text(
                _error!,
                style: const TextStyle(color: TeraColors.ink, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: TeraSpacing.lg),
          const Text(
            'Changing your password signs you out on every device, including this one.',
            style: TextStyle(
              color: TeraColors.neutral700,
              fontSize: TeraText.micro,
              height: 1.4,
            ),
          ),
          const SizedBox(height: TeraSpacing.md),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
              padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
            ),
            child: Text(_busy ? 'Saving...' : 'Change password'),
          ),
        ],
      ),
    ),
  );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String? Function(String?) validator,
  }) => TextFormField(
    controller: controller,
    enabled: !_busy,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    validator: validator,
  );
}

/// PROF-10 — close the account.
///
/// # What this actually does, and why the copy is so specific
///
/// It deletes the sign-in identity: the login subject and the password hash. It does **not** delete
/// the clinical record, which is retained under a pseudonym carrying no name and no contact detail
/// — every clinical table has a `BEFORE UPDATE OR DELETE` trigger enforcing invariant 5, and health
/// records are frequently the thing retention rules require you to keep.
///
/// So the screen does not say "this deletes everything". It says what goes and what stays, in two
/// lists, because a patient pressing this is entitled to know which of those two their readings
/// fall into — and because promising a total erasure the system cannot perform would be the more
/// serious failure of the two.
class CloseAccountScreen extends StatefulWidget {
  const CloseAccountScreen({
    super.key,
    required this.api,
    required this.onClosed,
    this.profileStore,
  });

  final ApiClient api;

  /// Called after the server has closed the account. The caller runs the local wipe and returns
  /// the patient to the door; it is not done here so that the same wipe used by sign-out is the
  /// one that runs, rather than a second copy of it.
  final VoidCallback onClosed;

  final PhrProfileStore? profileStore;

  @override
  State<CloseAccountScreen> createState() => _CloseAccountScreenState();
}

class _CloseAccountScreenState extends State<CloseAccountScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  bool _busy = false;
  String? _error;

  /// The word the patient has to type. Deliberately not localised and deliberately not a checkbox:
  /// this is the last step before something irreversible, and a tap is too cheap for it.
  static const String confirmationWord = 'DELETE';

  bool get _canSubmit =>
      _password.text.isNotEmpty &&
      _confirmation.text.trim().toUpperCase() == confirmationWord;

  @override
  void initState() {
    super.initState();
    _password.addListener(_refresh);
    _confirmation.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.postJson('/v1/auth/account/close', {'password': _password.text});
      if (!mounted) return;
      widget.onClosed();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.statusCode == 403 ? 'That is not your password.' : e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not close your account. $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'This cannot be undone',
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),
              _list(
                title: 'Deleted',
                items: const [
                  'Your email address and password',
                  'Your ability to sign in — this cannot be reversed or recovered',
                  'Everything Tera has stored on this phone',
                ],
              ),
              const SizedBox(height: TeraSpacing.md),
              _list(
                title: 'Kept, with nothing linking it to you',
                items: const [
                  'Your readings and checks, under a pseudonym',
                  'No name, email or contact detail is attached to them',
                  'A security log recording that this account existed and was closed',
                ],
              ),
              const SizedBox(height: TeraSpacing.md),
              Container(
                padding: const EdgeInsets.all(TeraSpacing.md),
                decoration: systemFlagDecoration(),
                child: const Text(
                  'Medical records are kept even after an account closes, because that is what '
                  'health-record rules require. What is removed is everything that ties those '
                  'readings to you.',
                  style: TextStyle(
                    color: TeraColors.ink,
                    fontSize: TeraText.small,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: TeraSpacing.xl),
              TextFormField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Your password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              TextFormField(
                controller: _confirmation,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Type $confirmationWord to confirm',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: TeraSpacing.md),
                Container(
                  padding: const EdgeInsets.all(TeraSpacing.md),
                  decoration: systemFlagDecoration(),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TeraColors.ink, height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: TeraSpacing.lg),
              FilledButton(
                // Both gates, and neither is decorative: the password is what the server checks,
                // and the typed word is what stops a mis-tap here reaching it.
                onPressed: (_busy || !_canSubmit) ? null : _close,
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.plum,
                  foregroundColor: TeraColors.paper,
                  disabledBackgroundColor: TeraColors.neutral300,
                  padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                ),
                child: Text(_busy ? 'Closing...' : 'Delete my account'),
              ),
              const SizedBox(height: TeraSpacing.sm),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Keep my account'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list({required String title, required List<String> items}) => Container(
    padding: const EdgeInsets.all(TeraSpacing.md),
    decoration: BoxDecoration(
      color: TeraColors.paper,
      borderRadius: BorderRadius.circular(TeraRadius.card),
      border: Border.all(color: TeraColors.neutral200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: TeraColors.ink,
            fontSize: TeraText.small,
          ),
        ),
        const SizedBox(height: TeraSpacing.sm),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ', style: TextStyle(color: TeraColors.neutral700)),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(
                      color: TeraColors.ink,
                      fontSize: TeraText.small,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
