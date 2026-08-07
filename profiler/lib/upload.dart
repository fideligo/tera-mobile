/// Optional upload to `POST /v1/device-profiles` (BUILD_SPEC 6.2).
///
/// Optional in the strict sense: the profiler's job is done once the numbers exist, and on a
/// measurement day the venue network is the least reliable thing in the room. Everything is
/// exportable without a backend.
///
/// The upload refuses when any field the API requires could not be measured. The API has no way
/// to record "not measured" for those fields, and sending a placeholder would put an invented
/// number into a clinical record — invariant 9.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'profile_result.dart';

class UploadCard extends StatefulWidget {
  const UploadCard({super.key, required this.result});

  final ProfileResult result;

  @override
  State<UploadCard> createState() => _UploadCardState();
}

class _UploadCardState extends State<UploadCard> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _patientId = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _expanded = false;
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _baseUrl.dispose();
    _patientId.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.result.uploadBlockedReason;

    return Container(
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB8C1C9))),
      child: ExpansionTile(
        title: const Text('Upload to a Tera backend (optional)'),
        subtitle: Text(
          blocked == null
              ? 'Sends this profile to POST /v1/device-profiles'
              : 'Unavailable — some measurements failed',
          style: const TextStyle(fontSize: 12),
        ),
        onExpansionChanged: (v) => setState(() => _expanded = v),
        initiallyExpanded: _expanded,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: blocked != null
                ? Text(blocked, style: const TextStyle(fontSize: 13, height: 1.4))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _field(_baseUrl, 'Backend URL', 'http://192.168.1.10:8000'),
                      _field(_patientId, 'Patient id (UUID)', ''),
                      _field(_username, 'Username', 'demo.patient@tera.invalid'),
                      _field(_password, 'Password', '', obscure: true),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _busy ? null : _upload,
                        child: Text(_busy ? 'Uploading…' : 'Upload'),
                      ),
                      if (_status != null) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          _status!,
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _status = null;
    });

    try {
      final payload = widget.result.toDeviceProfilePayload(_patientId.text.trim());
      if (payload == null) {
        setState(() => _status = widget.result.uploadBlockedReason);
        return;
      }

      final base = _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), '');
      if (base.isEmpty) {
        setState(() => _status = 'Enter the backend URL.');
        return;
      }

      final token = await _authenticate(base);
      if (token == null) return;

      final response = await http
          .post(
            Uri.parse('$base/v1/device-profiles'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 201) {
        final body = jsonDecode(response.body) as Map<String, Object?>;
        setState(
          () => _status =
              'Uploaded. The backend graded this handset: '
              '${body['qualified_status']}.\n'
              'The verdict is the backend\'s — the profiler only measures.',
        );
      } else {
        setState(
          () => _status = 'Upload failed (${response.statusCode}): ${response.body}',
        );
      }
    } on Object catch (e) {
      setState(() => _status = 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _authenticate(String base) async {
    try {
      final response = await http
          .post(
            Uri.parse('$base/v1/auth/token'),
            body: {'username': _username.text.trim(), 'password': _password.text},
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        setState(() => _status = 'Could not sign in (${response.statusCode}).');
        return null;
      }
      return (jsonDecode(response.body) as Map<String, Object?>)['access_token'] as String;
    } on Object catch (e) {
      setState(() => _status = 'Could not reach $base: $e');
      return null;
    }
  }
}
