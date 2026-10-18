import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User configuration. Secrets (API key, mail password) live in the platform
/// keystore (Android Keystore / Windows Credential Manager); the rest in
/// shared preferences.
class Settings {
  String anthropicApiKey;
  String model;
  bool useCloud;

  String city;
  bool useFahrenheit;

  String imapHost;
  int imapPort;
  String mailUser;
  String mailPassword;

  bool preferOnDeviceSpeech;
  String voiceLocale;
  String userTitle;

  Settings({
    this.anthropicApiKey = '',
    this.model = 'claude-opus-5-5',
    this.useCloud = true,
    this.city = '',
    this.useFahrenheit = false,
    this.imapHost = 'imap.gmail.com',
    this.imapPort = 993,
    this.mailUser = '',
    this.mailPassword = '',
    this.preferOnDeviceSpeech = false,
    this.voiceLocale = 'en-GB',
    this.userTitle = 'sir',
  });

  bool get hasCloud => useCloud && anthropicApiKey.isNotEmpty;
  bool get hasMail =>
      imapHost.isNotEmpty && mailUser.isNotEmpty && mailPassword.isNotEmpty;
}

class SettingsStore {
  static const _secure = FlutterSecureStorage();

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      anthropicApiKey: await _secure.read(key: 'anthropicApiKey') ?? '',
      mailPassword: await _secure.read(key: 'mailPassword') ?? '',
      model: p.getString('model') ?? 'claude-opus-5-5',
      useCloud: p.getBool('useCloud') ?? true,
      city: p.getString('city') ?? '',
      useFahrenheit: p.getBool('useFahrenheit') ?? false,
      imapHost: p.getString('imapHost') ?? 'imap.gmail.com',
      imapPort: p.getInt('imapPort') ?? 993,
      mailUser: p.getString('mailUser') ?? '',
      preferOnDeviceSpeech: p.getBool('preferOnDeviceSpeech') ?? false,
      voiceLocale: p.getString('voiceLocale') ?? 'en-GB',
      userTitle: p.getString('userTitle') ?? 'sir',
    );
  }

  static Future<void> save(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await _secure.write(key: 'anthropicApiKey', value: s.anthropicApiKey);
    await _secure.write(key: 'mailPassword', value: s.mailPassword);
    await p.setString('model', s.model);
    await p.setBool('useCloud', s.useCloud);
    await p.setString('city', s.city);
    await p.setBool('useFahrenheit', s.useFahrenheit);
    await p.setString('imapHost', s.imapHost);
    await p.setInt('imapPort', s.imapPort);
    await p.setString('mailUser', s.mailUser);
    await p.setBool('preferOnDeviceSpeech', s.preferOnDeviceSpeech);
    await p.setString('voiceLocale', s.voiceLocale);
    await p.setString('userTitle', s.userTitle);
  }
}
