import 'package:flutter/material.dart';

import '../config/settings.dart';

class SettingsScreen extends StatefulWidget {
  final Settings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _apiKey = TextEditingController(text: widget.settings.anthropicApiKey);
  late final _model = TextEditingController(text: widget.settings.model);
  late final _city = TextEditingController(text: widget.settings.city);
  late final _imapHost = TextEditingController(text: widget.settings.imapHost);
  late final _imapPort =
      TextEditingController(text: '${widget.settings.imapPort}');
  late final _mailUser = TextEditingController(text: widget.settings.mailUser);
  late final _mailPass =
      TextEditingController(text: widget.settings.mailPassword);
  late final _locale = TextEditingController(text: widget.settings.voiceLocale);
  late final _title = TextEditingController(text: widget.settings.userTitle);
  late bool _useCloud = widget.settings.useCloud;
  late bool _fahrenheit = widget.settings.useFahrenheit;
  late bool _onDevice = widget.settings.preferOnDeviceSpeech;
  bool _showSecrets = false;

  void _save() {
    Navigator.of(context).pop(Settings(
      anthropicApiKey: _apiKey.text.trim(),
      model: _model.text.trim().isEmpty ? 'claude-opus-5-5' : _model.text.trim(),
      useCloud: _useCloud,
      city: _city.text.trim(),
      useFahrenheit: _fahrenheit,
      imapHost: _imapHost.text.trim(),
      imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
      mailUser: _mailUser.text.trim(),
      mailPassword: _mailPass.text,
      preferOnDeviceSpeech: _onDevice,
      voiceLocale: _locale.text.trim().isEmpty ? 'en-GB' : _locale.text.trim(),
      userTitle: _title.text.trim().isEmpty ? 'sir' : _title.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Cloud brain (Claude)'),
          SwitchListTile(
            title: const Text('Use cloud for open-ended questions'),
            subtitle: const Text(
                'Time, weather and email always work on-device as well.'),
            value: _useCloud,
            onChanged: (v) => setState(() => _useCloud = v),
          ),
          _field(_apiKey, 'Anthropic API key', secret: true,
              help: 'From console.anthropic.com. Stored in the OS keystore.'),
          _field(_model, 'Model'),
          _section('Weather'),
          _field(_city, 'Home city', help: 'e.g. Chennai, London, New York'),
          SwitchListTile(
            title: const Text('Use Fahrenheit'),
            value: _fahrenheit,
            onChanged: (v) => setState(() => _fahrenheit = v),
          ),
          _section('Email (IMAP)'),
          _field(_imapHost, 'IMAP server',
              help: 'Gmail: imap.gmail.com  ·  Outlook: outlook.office365.com'),
          _field(_imapPort, 'Port', keyboard: TextInputType.number),
          _field(_mailUser, 'Email address'),
          _field(_mailPass, 'App password', secret: true,
              help: 'Gmail needs an app password: Google Account → Security → '
                  '2-Step Verification → App passwords.'),
          _section('Voice'),
          _field(_locale, 'Voice language', help: 'e.g. en-GB, en-US, en-IN'),
          _field(_title, 'How JARVIS addresses you', help: 'sir, ma\'am, boss…'),
          SwitchListTile(
            title: const Text('On-device speech recognition only'),
            subtitle: const Text(
                'Android: needs the offline speech pack for your language.'),
            value: _onDevice,
            onChanged: (v) => setState(() => _onDevice = v),
          ),
          CheckboxListTile(
            title: const Text('Show secrets'),
            value: _showSecrets,
            onChanged: (v) => setState(() => _showSecrets = v ?? false),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _field(TextEditingController c, String label,
          {bool secret = false, String? help, TextInputType? keyboard}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          obscureText: secret && !_showSecrets,
          keyboardType: keyboard,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            helperMaxLines: 2,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}
