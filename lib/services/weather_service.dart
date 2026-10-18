import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cache.dart';

/// Weather from Open-Meteo (free, no API key). The last successful result
/// per city is cached so it can still be reported offline.
class WeatherService {
  final http.Client _http;
  static const _timeout = Duration(seconds: 8);

  WeatherService({http.Client? client}) : _http = client ?? http.Client();

  Future<Cached<Map<String, dynamic>>> getWeather(
    String city, {
    bool fahrenheit = false,
  }) async {
    final key = 'weather.${city.toLowerCase()}.${fahrenheit ? 'f' : 'c'}';
    try {
      final place = await _geocode(city);
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '${place['latitude']}',
        'longitude': '${place['longitude']}',
        'current':
            'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m',
        'daily':
            'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'timezone': 'auto',
        'forecast_days': '1',
        'temperature_unit': fahrenheit ? 'fahrenheit' : 'celsius',
        'wind_speed_unit': fahrenheit ? 'mph' : 'kmh',
      });
      final res = await _http.get(uri).timeout(_timeout);
      if (res.statusCode != 200) {
        throw WeatherException('Weather service returned ${res.statusCode}');
      }
      final d = jsonDecode(res.body) as Map<String, dynamic>;
      final cur = d['current'] as Map<String, dynamic>;
      final daily = d['daily'] as Map<String, dynamic>;
      final result = <String, dynamic>{
        'location': place['name'],
        'unit': fahrenheit ? 'F' : 'C',
        'wind_unit': fahrenheit ? 'mph' : 'km/h',
        'temperature': cur['temperature_2m'],
        'feels_like': cur['apparent_temperature'],
        'humidity': cur['relative_humidity_2m'],
        'wind_speed': cur['wind_speed_10m'],
        'condition': describeWeatherCode((cur['weather_code'] as num).toInt()),
        'high': (daily['temperature_2m_max'] as List).first,
        'low': (daily['temperature_2m_min'] as List).first,
        'rain_chance': (daily['precipitation_probability_max'] as List).first,
      };
      await JsonCache.put(key, result);
      return Cached(result, DateTime.now());
    } catch (e) {
      final cached = await JsonCache.get(key);
      if (cached != null) return cached;
      if (e is WeatherException) rethrow;
      throw WeatherException('I cannot reach the weather service right now');
    }
  }

  Future<Map<String, dynamic>> _geocode(String city) async {
    final key = 'geo.${city.toLowerCase()}';
    final cached = await JsonCache.get(key);
    if (cached != null) return cached.value;
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': city,
      'count': '1',
      'language': 'en',
    });
    final res = await _http.get(uri).timeout(_timeout);
    final d = jsonDecode(res.body) as Map<String, dynamic>;
    final results = d['results'] as List?;
    if (results == null || results.isEmpty) {
      throw WeatherException('I could not find a place called $city');
    }
    final r = results.first as Map<String, dynamic>;
    final place = <String, dynamic>{
      'name': r['name'],
      'latitude': r['latitude'],
      'longitude': r['longitude'],
    };
    await JsonCache.put(key, place);
    return place;
  }
}

class WeatherException implements Exception {
  final String message;
  WeatherException(this.message);
  @override
  String toString() => message;
}

/// WMO weather interpretation codes, as used by Open-Meteo.
String describeWeatherCode(int code) {
  if (code == 0) return 'clear skies';
  if (code <= 2) return 'partly cloudy';
  if (code == 3) return 'overcast';
  if (code <= 48) return 'foggy';
  if (code <= 57) return 'drizzle';
  if (code <= 67) return 'rain';
  if (code <= 77) return 'snow';
  if (code <= 82) return 'rain showers';
  if (code <= 86) return 'snow showers';
  return 'thunderstorms';
}
