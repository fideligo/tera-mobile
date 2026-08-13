import 'package:flutter/material.dart';
import '../auth/auth_controller.dart';
import '../routing/routes.dart';
import '../api/api_client.dart';
import 'tokens.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isBusy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    final success = await widget.auth.register(
      subject: _emailController.text.trim(),
      password: _passwordController.text,
    );

    if (!mounted) return;
    setState(() => _isBusy = false);

    if (success) {
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(Routes.splash, (r) => false);
    } else {
      setState(() => _errorMessage = widget.auth.error);
    }
  }

  /// Skip sign-up entirely, matching the sign-in screen's own guest route.
  void _continueAsGuest() {
    widget.auth.continueAsGuest();
    Navigator.of(context).pushNamedAndRemoveUntil(Routes.home, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: TeraSpacing.xxl),
                const Text(
                  'Buat Akun Baru',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(height: TeraSpacing.sm),
                const Text(
                  'Daftar untuk mulai memantau tekanan darahmu',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.neutral700,
                  ),
                ),
                const SizedBox(height: TeraSpacing.xl),
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(TeraSpacing.md),
                    decoration: systemFlagDecoration(),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: TeraColors.ink,
                        fontSize: TeraText.body,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.md),
                ],
                Container(
                  decoration: BoxDecoration(
                    color: TeraColors.page,
                    borderRadius: BorderRadius.circular(TeraRadius.card),
                  ),
                  padding: const EdgeInsets.all(TeraSpacing.lg),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _nameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Nama Lengkap',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                TeraRadius.field,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: TeraSpacing.md,
                              vertical: TeraSpacing.md,
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Nama tidak boleh kosong';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: TeraSpacing.md),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                TeraRadius.field,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: TeraSpacing.md,
                              vertical: TeraSpacing.md,
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Email tidak boleh kosong';
                            }
                            // Permissive on purpose — it catches the typo, not the domain.
                            // Without it a missing '@' costs a round trip to find out.
                            if (!RegExp(
                              r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                            ).hasMatch(value.trim())) {
                              return 'Masukkan email yang valid, cth: nama@email.com';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: TeraSpacing.md),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            labelText: 'Kata Sandi',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                TeraRadius.field,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: TeraSpacing.md,
                              vertical: TeraSpacing.md,
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: TeraColors.neutral500,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Kata Sandi tidak boleh kosong';
                            }
                            // The backend's own minimum, not a second opinion. At 8 this form
                            // accepted passwords the server then refused with a 422, so the
                            // patient was told the rule only after failing it.
                            if (value.length < minPasswordLength) {
                              return 'Kata sandi minimal $minPasswordLength karakter';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: TeraSpacing.xl),
                        ElevatedButton(
                          onPressed: _isBusy ? null : _register,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: TeraColors.ink,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              vertical: TeraSpacing.md,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                TeraRadius.button,
                              ),
                            ),
                            elevation: 0,
                          ),
                          child: _isBusy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  'Register',
                                  style: TextStyle(
                                    fontSize: TeraText.body,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: TeraSpacing.lg),

                // ── Guest ──
                //
                // Same option as the sign-in screen, because someone who lands on Register and
                // does not want an account has otherwise no way forward but the back button.
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _isBusy ? null : _continueAsGuest,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TeraColors.brand,
                      side: const BorderSide(color: TeraColors.brand),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(TeraRadius.button),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Sudah punya akun?',
                      style: TextStyle(
                        color: TeraColors.neutral700,
                        fontSize: TeraText.small,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: const Text(
                        'Login',
                        style: TextStyle(
                          // Baltic is the palette's link colour; the raw navy here was neither a
                          // token nor the link token.
                          color: TeraColors.baltic,
                          fontWeight: FontWeight.bold,
                          fontSize: TeraText.small,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TeraSpacing.xxl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
