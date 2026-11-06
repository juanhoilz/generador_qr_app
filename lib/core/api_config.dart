class ApiConfig {
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.1.16/horaexactaapp/web/api',
  );

  static Uri endpoint(String path) => Uri.parse('$baseUrl/$path');
}
