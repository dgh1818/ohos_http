#include <atomic>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>

#include <js_native_api.h>
#include <napi/native_api.h>

#include "dart_api_dl.h"

#ifdef IMMICH_OHOS_HAS_LIBCURL
#include <curl/curl.h>

extern "C" {
typedef struct bio_st BIO;
typedef struct evp_pkey_st EVP_PKEY;
typedef struct pkcs12_st PKCS12;
typedef struct stack_st OPENSSL_STACK;
typedef struct stack_st_X509 STACK_OF_X509;
typedef struct x509_st X509;

BIO* BIO_new_file(const char* filename, const char* mode);
int BIO_free(BIO* bio);
void EVP_PKEY_free(EVP_PKEY* key);
PKCS12* d2i_PKCS12_bio(BIO* bio, PKCS12** pkcs12);
void PKCS12_free(PKCS12* pkcs12);
int PKCS12_parse(PKCS12* pkcs12, const char* password, EVP_PKEY** pkey, X509** cert, STACK_OF_X509** ca);
void OPENSSL_sk_free(OPENSSL_STACK* stack);
int OPENSSL_sk_num(const OPENSSL_STACK* stack);
void* OPENSSL_sk_value(const OPENSSL_STACK* stack, int index);
int PEM_write_bio_X509(BIO* bio, X509* cert);
void X509_free(X509* cert);
}
#endif

namespace {

constexpr int32_t kLibraryVersion = 1;
constexpr int32_t kPingValue = 0x4F484646;
constexpr int32_t kBootstrapCompiled = 1 << 0;
constexpr int32_t kDispatcherInstalled = 1 << 1;
constexpr int32_t kLibcurlEnabled = 1 << 2;
constexpr const char* kRemoteValidationHeader = "x-ohos-http-remote-validation";
constexpr const char* kRemoteValidationSkip = "skip";

constexpr int32_t kDispatchOk = 0;
constexpr int32_t kDispatchMissingDispatcher = 1;
constexpr int32_t kDispatchInvalidArgument = 2;
constexpr int32_t kDispatchQueueFailed = 3;
constexpr int32_t kConfigParseFailed = 4;
constexpr int32_t kCertificateExtractionFailed = 5;
constexpr int32_t kCertificateNoCaBundle = 6;

struct RequestTask {
  int64_t request_id;
  int64_t dart_port;
  std::string method;
  std::string url;
  std::string headers_json;
  std::vector<uint8_t> body;
  int32_t connect_timeout_ms;
  int32_t read_timeout_ms;
};

struct StreamRequestTask : RequestTask {
  std::atomic<bool> cancelled{false};
};

struct MultipartFilePart {
  std::string field_name;
  std::string file_path;
  std::string file_name;
  std::string content_type;
};

struct MultipartRequestTask {
  int64_t request_id;
  int64_t dart_port;
  std::string method;
  std::string url;
  std::string headers_json;
  std::string fields_json;
  std::string files_json;
  int32_t connect_timeout_ms;
  int32_t read_timeout_ms;
  std::atomic<bool> cancelled{false};
  std::atomic<int64_t> last_uploaded_bytes{-1};
  std::atomic<int64_t> last_total_bytes{-1};
};

struct SessionState {
  std::map<std::string, std::string> request_headers;
  std::vector<std::string> server_urls;
  std::string access_token;
  std::string cert_path;
  std::string key_path;
  std::string cert_type;
  std::string key_password;
  std::string ca_bundle_path;
};

bool PostFailureToDart(int64_t dart_port, int64_t request_id, const std::string& code, const std::string& message);

bool PostSuccessToDart(
    int64_t dart_port,
    int64_t request_id,
    int32_t status_code,
    const std::string& headers_json,
    const uint8_t* body,
    intptr_t body_length);

bool PostStreamHeadersToDart(
  int64_t dart_port,
  int64_t request_id,
  int32_t status_code,
  const std::string& headers_json);

bool PostStreamChunkToDart(int64_t dart_port, int64_t request_id, const uint8_t* chunk, intptr_t chunk_length);

bool PostStreamCompleteToDart(int64_t dart_port, int64_t request_id, int32_t status_code);

bool PostStreamErrorToDart(int64_t dart_port, int64_t request_id, const std::string& code, const std::string& message);

bool PostMultipartProgressToDart(int64_t dart_port, int64_t request_id, int64_t bytes_sent, int64_t total_bytes);

#ifdef IMMICH_OHOS_HAS_LIBCURL
constexpr int32_t kInitialBootstrapState = kBootstrapCompiled | kLibcurlEnabled;
#else
constexpr int32_t kInitialBootstrapState = kBootstrapCompiled;
#endif

std::atomic<int32_t> g_bootstrap_state(kInitialBootstrapState);
std::mutex g_dispatcher_mutex;
napi_threadsafe_function g_dispatcher = nullptr;
std::mutex g_session_mutex;
SessionState g_session_state;
std::mutex g_stream_mutex;
std::map<int64_t, std::shared_ptr<StreamRequestTask>> g_stream_requests;
std::mutex g_multipart_mutex;
std::map<int64_t, std::shared_ptr<MultipartRequestTask>> g_multipart_requests;

#ifdef IMMICH_OHOS_HAS_LIBCURL
std::once_flag g_curl_init_once;
CURLcode g_curl_init_result = CURLE_OK;

struct CurlResponse {
  std::vector<uint8_t> body;
  std::map<std::string, std::string> headers;
  long status_code = 0;
  int64_t dart_port = 0;
  int64_t request_id = 0;
  bool headers_sent = false;
};

struct CurlMultipartFileSource {
  FILE* file = nullptr;
};

template <typename Value>
bool SetCurlOption(CURL* handle, CURLoption option, const char* option_name, Value value, std::string* error) {
  const CURLcode result = curl_easy_setopt(handle, option, value);
  if (result == CURLE_OK) {
    return true;
  }
  if (error != nullptr) {
    *error = std::string(option_name) + ": " + curl_easy_strerror(result);
  }
  return false;
}

size_t CurlMultipartFileReadCallback(char* buffer, size_t size, size_t nitems, void* user_data) {
  if (buffer == nullptr || user_data == nullptr || size == 0 || nitems == 0) {
    return 0;
  }

  auto* source = static_cast<CurlMultipartFileSource*>(user_data);
  if (source->file == nullptr) {
    return 0;
  }

  return std::fread(buffer, 1, size * nitems, source->file);
}

int CurlMultipartFileSeekCallback(void* user_data, curl_off_t offset, int origin) {
  if (user_data == nullptr) {
    return CURL_SEEKFUNC_FAIL;
  }

  auto* source = static_cast<CurlMultipartFileSource*>(user_data);
  if (source->file == nullptr) {
    return CURL_SEEKFUNC_FAIL;
  }

  return fseeko(source->file, static_cast<off_t>(offset), origin) == 0
      ? CURL_SEEKFUNC_OK
      : CURL_SEEKFUNC_FAIL;
}

bool IsJsonWhitespace(char value) {
  return value == ' ' || value == '\n' || value == '\r' || value == '\t';
}

void SkipJsonWhitespace(const std::string& source, size_t* index) {
  while (*index < source.size() && IsJsonWhitespace(source[*index])) {
    ++(*index);
  }
}

bool ParseHexDigit(char value, uint32_t* digit) {
  if (value >= '0' && value <= '9') {
    *digit = static_cast<uint32_t>(value - '0');
    return true;
  }
  if (value >= 'a' && value <= 'f') {
    *digit = static_cast<uint32_t>(value - 'a' + 10);
    return true;
  }
  if (value >= 'A' && value <= 'F') {
    *digit = static_cast<uint32_t>(value - 'A' + 10);
    return true;
  }
  return false;
}

void AppendUtf8Codepoint(uint32_t codepoint, std::string* output) {
  if (codepoint <= 0x7F) {
    output->push_back(static_cast<char>(codepoint));
    return;
  }
  if (codepoint <= 0x7FF) {
    output->push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
    output->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    return;
  }
  if (codepoint <= 0xFFFF) {
    output->push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
    output->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
    output->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    return;
  }
  output->push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
  output->push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
  output->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
  output->push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
}

bool ParseJsonString(const std::string& source, size_t* index, std::string* value) {
  if (*index >= source.size() || source[*index] != '"') {
    return false;
  }
  ++(*index);

  std::string output;
  while (*index < source.size()) {
    const char ch = source[*index];
    ++(*index);
    if (ch == '"') {
      *value = output;
      return true;
    }
    if (ch != '\\') {
      output.push_back(ch);
      continue;
    }
    if (*index >= source.size()) {
      return false;
    }

    const char escaped = source[*index];
    ++(*index);
    switch (escaped) {
      case '"':
      case '\\':
      case '/':
        output.push_back(escaped);
        break;
      case 'b':
        output.push_back('\b');
        break;
      case 'f':
        output.push_back('\f');
        break;
      case 'n':
        output.push_back('\n');
        break;
      case 'r':
        output.push_back('\r');
        break;
      case 't':
        output.push_back('\t');
        break;
      case 'u': {
        if (*index + 4 > source.size()) {
          return false;
        }
        uint32_t codepoint = 0;
        for (int i = 0; i < 4; ++i) {
          uint32_t digit = 0;
          if (!ParseHexDigit(source[*index + i], &digit)) {
            return false;
          }
          codepoint = (codepoint << 4) | digit;
        }
        *index += 4;
        AppendUtf8Codepoint(codepoint, &output);
        break;
      }
      default:
        return false;
    }
  }

  return false;
}

bool ParseJsonHeaderObject(const std::string& headers_json, std::vector<std::pair<std::string, std::string>>* headers_out, std::string* error) {
  size_t index = 0;
  SkipJsonWhitespace(headers_json, &index);
  if (index >= headers_json.size() || headers_json[index] != '{') {
    if (error != nullptr) {
      *error = "Headers JSON must be an object.";
    }
    return false;
  }
  ++index;

  while (true) {
    SkipJsonWhitespace(headers_json, &index);
    if (index >= headers_json.size()) {
      if (error != nullptr) {
        *error = "Headers JSON ended unexpectedly.";
      }
      return false;
    }
    if (headers_json[index] == '}') {
      ++index;
      SkipJsonWhitespace(headers_json, &index);
      if (index != headers_json.size()) {
        if (error != nullptr) {
          *error = "Headers JSON has trailing content.";
        }
        return false;
      }
      return true;
    }

    std::string key;
    std::string value;
    if (!ParseJsonString(headers_json, &index, &key)) {
      if (error != nullptr) {
        *error = "Failed to parse a header key.";
      }
      return false;
    }

    SkipJsonWhitespace(headers_json, &index);
    if (index >= headers_json.size() || headers_json[index] != ':') {
      if (error != nullptr) {
        *error = "Header key is missing a value separator.";
      }
      return false;
    }
    ++index;
    SkipJsonWhitespace(headers_json, &index);

    if (!ParseJsonString(headers_json, &index, &value)) {
      if (error != nullptr) {
        *error = "Failed to parse a header value.";
      }
      return false;
    }
    headers_out->push_back(std::make_pair(key, value));

    SkipJsonWhitespace(headers_json, &index);
    if (index >= headers_json.size()) {
      if (error != nullptr) {
        *error = "Headers JSON ended unexpectedly after a header value.";
      }
      return false;
    }
    if (headers_json[index] == ',') {
      ++index;
      continue;
    }
    if (headers_json[index] == '}') {
      continue;
    }
    if (error != nullptr) {
      *error = "Headers JSON has an unexpected token between entries.";
    }
    return false;
  }
}

bool ParseJsonStringArray(const std::string& source, std::vector<std::string>* values_out, std::string* error) {
  size_t index = 0;
  SkipJsonWhitespace(source, &index);
  if (index >= source.size() || source[index] != '[') {
    if (error != nullptr) {
      *error = "Expected a JSON array.";
    }
    return false;
  }
  ++index;

  while (true) {
    SkipJsonWhitespace(source, &index);
    if (index >= source.size()) {
      if (error != nullptr) {
        *error = "JSON array ended unexpectedly.";
      }
      return false;
    }
    if (source[index] == ']') {
      ++index;
      SkipJsonWhitespace(source, &index);
      if (index != source.size()) {
        if (error != nullptr) {
          *error = "JSON array has trailing content.";
        }
        return false;
      }
      return true;
    }

    std::string value;
    if (!ParseJsonString(source, &index, &value)) {
      if (error != nullptr) {
        *error = "Failed to parse a JSON string array entry.";
      }
      return false;
    }
    values_out->push_back(value);

    SkipJsonWhitespace(source, &index);
    if (index >= source.size()) {
      if (error != nullptr) {
        *error = "JSON array ended unexpectedly after an entry.";
      }
      return false;
    }
    if (source[index] == ',') {
      ++index;
      continue;
    }
    if (source[index] == ']') {
      continue;
    }
    if (error != nullptr) {
      *error = "JSON array has an unexpected token between entries.";
    }
    return false;
  }
}

bool AssignMultipartFileProperty(
    MultipartFilePart* part,
    const std::string& key,
    const std::string& value,
    std::string* error) {
  if (key == "field") {
    part->field_name = value;
    return true;
  }
  if (key == "filePath") {
    part->file_path = value;
    return true;
  }
  if (key == "fileName") {
    part->file_name = value;
    return true;
  }
  if (key == "contentType") {
    part->content_type = value;
    return true;
  }
  if (error != nullptr) {
    *error = "Multipart file JSON contains an unknown key: " + key;
  }
  return false;
}

bool ParseJsonMultipartFilesArray(
    const std::string& source,
    std::vector<MultipartFilePart>* files_out,
    std::string* error) {
  size_t index = 0;
  SkipJsonWhitespace(source, &index);
  if (index >= source.size() || source[index] != '[') {
    if (error != nullptr) {
      *error = "Multipart files JSON must be an array.";
    }
    return false;
  }
  ++index;

  while (true) {
    SkipJsonWhitespace(source, &index);
    if (index >= source.size()) {
      if (error != nullptr) {
        *error = "Multipart files JSON ended unexpectedly.";
      }
      return false;
    }
    if (source[index] == ']') {
      ++index;
      SkipJsonWhitespace(source, &index);
      if (index != source.size()) {
        if (error != nullptr) {
          *error = "Multipart files JSON has trailing content.";
        }
        return false;
      }
      return true;
    }
    if (source[index] != '{') {
      if (error != nullptr) {
        *error = "Multipart files JSON entries must be objects.";
      }
      return false;
    }
    ++index;

    MultipartFilePart file_part;
    while (true) {
      SkipJsonWhitespace(source, &index);
      if (index >= source.size()) {
        if (error != nullptr) {
          *error = "Multipart file object ended unexpectedly.";
        }
        return false;
      }
      if (source[index] == '}') {
        ++index;
        break;
      }

      std::string key;
      if (!ParseJsonString(source, &index, &key)) {
        if (error != nullptr) {
          *error = "Failed to parse a multipart file key.";
        }
        return false;
      }

      SkipJsonWhitespace(source, &index);
      if (index >= source.size() || source[index] != ':') {
        if (error != nullptr) {
          *error = "Multipart file key is missing a value separator.";
        }
        return false;
      }
      ++index;
      SkipJsonWhitespace(source, &index);

      std::string value;
      if (!ParseJsonString(source, &index, &value)) {
        if (error != nullptr) {
          *error = "Failed to parse a multipart file value.";
        }
        return false;
      }
      if (!AssignMultipartFileProperty(&file_part, key, value, error)) {
        return false;
      }

      SkipJsonWhitespace(source, &index);
      if (index >= source.size()) {
        if (error != nullptr) {
          *error = "Multipart file object ended unexpectedly after a value.";
        }
        return false;
      }
      if (source[index] == ',') {
        ++index;
        continue;
      }
      if (source[index] == '}') {
        continue;
      }
      if (error != nullptr) {
        *error = "Multipart file object has an unexpected token between entries.";
      }
      return false;
    }

    if (file_part.field_name.empty() || file_part.file_path.empty()) {
      if (error != nullptr) {
        *error = "Multipart file entries require non-empty field and filePath values.";
      }
      return false;
    }
    files_out->push_back(file_part);

    SkipJsonWhitespace(source, &index);
    if (index >= source.size()) {
      if (error != nullptr) {
        *error = "Multipart files JSON ended unexpectedly after an entry.";
      }
      return false;
    }
    if (source[index] == ',') {
      ++index;
      continue;
    }
    if (source[index] == ']') {
      continue;
    }
    if (error != nullptr) {
      *error = "Multipart files JSON has an unexpected token between entries.";
    }
    return false;
  }
}

std::string TrimAsciiWhitespace(const std::string& value) {
  size_t start = 0;
  size_t end = value.size();
  while (start < end && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
    ++start;
  }
  while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
    --end;
  }
  return value.substr(start, end - start);
}

bool ParseHttpStatusCode(const std::string& line, long* status_code_out) {
  if (status_code_out == nullptr) {
    return false;
  }

  const size_t first_space = line.find(' ');
  if (first_space == std::string::npos) {
    return false;
  }

  const size_t second_space = line.find(' ', first_space + 1);
  const std::string status_text = second_space == std::string::npos
      ? line.substr(first_space + 1)
      : line.substr(first_space + 1, second_space - first_space - 1);
  if (status_text.empty()) {
    return false;
  }

  char* end = nullptr;
  const long parsed_status = std::strtol(status_text.c_str(), &end, 10);
  if (end == nullptr || *end != '\0') {
    return false;
  }

  *status_code_out = parsed_status;
  return true;
}

std::string EscapeJsonString(const std::string& value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (unsigned char ch : value) {
    switch (ch) {
      case '\\':
        escaped += "\\\\";
        break;
      case '"':
        escaped += "\\\"";
        break;
      case '\b':
        escaped += "\\b";
        break;
      case '\f':
        escaped += "\\f";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        if (ch < 0x20) {
          const char* hex = "0123456789abcdef";
          escaped += "\\u00";
          escaped.push_back(hex[(ch >> 4) & 0x0F]);
          escaped.push_back(hex[ch & 0x0F]);
        } else {
          escaped.push_back(static_cast<char>(ch));
        }
        break;
    }
  }
  return escaped;
}

std::string SerializeHeadersJson(const std::map<std::string, std::string>& headers) {
  std::string json = "{";
  bool first = true;
  for (const auto& entry : headers) {
    if (!first) {
      json.push_back(',');
    }
    first = false;
    json.push_back('"');
    json += EscapeJsonString(entry.first);
    json += "\":";
    json.push_back('"');
    json += EscapeJsonString(entry.second);
    json.push_back('"');
  }
  json.push_back('}');
  return json;
}

bool MaybePostStreamHeaders(CurlResponse* response) {
  if (response == nullptr || response->headers_sent) {
    return true;
  }

  const std::string headers_json = SerializeHeadersJson(response->headers);
  if (!PostStreamHeadersToDart(
          response->dart_port,
          response->request_id,
          static_cast<int32_t>(response->status_code),
          headers_json)) {
    return false;
  }

  response->headers_sent = true;
  return true;
}

std::string ToLowerAscii(const std::string& value) {
  std::string lowered = value;
  for (char& ch : lowered) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return lowered;
}

bool AreHeaderNamesEqual(const std::string& left, const char* right) {
  return ToLowerAscii(left) == ToLowerAscii(std::string(right));
}

int FindHeaderIndex(const std::vector<std::pair<std::string, std::string>>& headers, const char* target_name) {
  for (size_t index = 0; index < headers.size(); ++index) {
    if (AreHeaderNamesEqual(headers[index].first, target_name)) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

void RemoveHeader(std::vector<std::pair<std::string, std::string>>* headers, const char* target_name) {
  if (headers == nullptr) {
    return;
  }

  for (auto it = headers->begin(); it != headers->end();) {
    if (AreHeaderNamesEqual(it->first, target_name)) {
      it = headers->erase(it);
      continue;
    }
    ++it;
  }
}

bool ConsumeRemoteValidationSkip(std::vector<std::pair<std::string, std::string>>* headers) {
  if (headers == nullptr) {
    return false;
  }

  bool should_skip = false;
  for (auto it = headers->begin(); it != headers->end();) {
    if (!AreHeaderNamesEqual(it->first, kRemoteValidationHeader)) {
      ++it;
      continue;
    }

    const std::string value = ToLowerAscii(it->second);
    if (value == kRemoteValidationSkip || value == "true" || value == "1") {
      should_skip = true;
    }
    it = headers->erase(it);
  }
  return should_skip;
}

bool ApplyCurlSslOptions(
    CURL* handle,
    const SessionState& session,
    bool skip_remote_validation,
    bool is_secure_request,
    std::string* error) {
  if (handle == nullptr) {
    if (error != nullptr) {
      *error = "CURL handle is null.";
    }
    return false;
  }

  if (!is_secure_request) {
    return true;
  }

  if (skip_remote_validation) {
    if (!SetCurlOption(handle, CURLOPT_SSL_VERIFYPEER, "CURLOPT_SSL_VERIFYPEER", 0L, error) ||
        !SetCurlOption(handle, CURLOPT_SSL_VERIFYHOST, "CURLOPT_SSL_VERIFYHOST", 0L, error)) {
      return false;
    }
  }

  if (!session.ca_bundle_path.empty()) {
    if (!SetCurlOption(handle, CURLOPT_CAINFO, "CURLOPT_CAINFO", session.ca_bundle_path.c_str(), error)) {
      return false;
    }
  }

  if (session.cert_path.empty()) {
    return true;
  }

  if (!SetCurlOption(handle, CURLOPT_SSLCERT, "CURLOPT_SSLCERT", session.cert_path.c_str(), error)) {
    return false;
  }
  if (!session.cert_type.empty()) {
    if (!SetCurlOption(handle, CURLOPT_SSLCERTTYPE, "CURLOPT_SSLCERTTYPE", session.cert_type.c_str(), error)) {
      return false;
    }
  }
  if (!session.key_password.empty()) {
    if (!SetCurlOption(handle, CURLOPT_KEYPASSWD, "CURLOPT_KEYPASSWD", session.key_password.c_str(), error)) {
      return false;
    }
  }
  if (!session.key_path.empty() && session.key_path != session.cert_path && session.cert_type != "P12") {
    if (!SetCurlOption(handle, CURLOPT_SSLKEY, "CURLOPT_SSLKEY", session.key_path.c_str(), error)) {
      return false;
    }
  }
  return true;
}

bool ApplyCurlMethodAndBody(CURL* handle, const std::string& method, const std::vector<uint8_t>& body, std::string* error) {
  if (handle == nullptr) {
    if (error != nullptr) {
      *error = "CURL handle is null.";
    }
    return false;
  }

  if (method == "HEAD") {
    return SetCurlOption(handle, CURLOPT_NOBODY, "CURLOPT_NOBODY", 1L, error);
  }

  if (method == "POST") {
    if (!SetCurlOption(handle, CURLOPT_POST, "CURLOPT_POST", 1L, error)) {
      return false;
    }
    if (!body.empty()) {
      return SetCurlOption(handle, CURLOPT_POSTFIELDS, "CURLOPT_POSTFIELDS", reinterpret_cast<const char*>(body.data()), error) &&
          SetCurlOption(
              handle, CURLOPT_POSTFIELDSIZE_LARGE, "CURLOPT_POSTFIELDSIZE_LARGE", static_cast<curl_off_t>(body.size()), error);
    } else {
      return SetCurlOption(handle, CURLOPT_POSTFIELDS, "CURLOPT_POSTFIELDS", "", error) &&
          SetCurlOption(handle, CURLOPT_POSTFIELDSIZE, "CURLOPT_POSTFIELDSIZE", 0L, error);
    }
  }

  if (method != "GET") {
    if (!SetCurlOption(handle, CURLOPT_CUSTOMREQUEST, "CURLOPT_CUSTOMREQUEST", method.c_str(), error)) {
      return false;
    }
  }

  if (!body.empty()) {
    return SetCurlOption(handle, CURLOPT_POSTFIELDS, "CURLOPT_POSTFIELDS", reinterpret_cast<const char*>(body.data()), error) &&
        SetCurlOption(
            handle, CURLOPT_POSTFIELDSIZE_LARGE, "CURLOPT_POSTFIELDSIZE_LARGE", static_cast<curl_off_t>(body.size()), error);
  }
  return true;
}

bool ParseUrlHostAndSecurity(const std::string& raw_url, std::string* host_out, bool* secure_out) {
  const size_t scheme_separator = raw_url.find("://");
  if (scheme_separator == std::string::npos) {
    return false;
  }

  const std::string scheme = ToLowerAscii(raw_url.substr(0, scheme_separator));
  const size_t authority_start = scheme_separator + 3;
  const size_t authority_end = raw_url.find_first_of("/?#", authority_start);
  std::string authority = raw_url.substr(authority_start, authority_end - authority_start);
  const size_t userinfo_separator = authority.rfind('@');
  if (userinfo_separator != std::string::npos) {
    authority = authority.substr(userinfo_separator + 1);
  }
  if (authority.empty()) {
    return false;
  }

  std::string host;
  if (authority[0] == '[') {
    const size_t closing_bracket = authority.find(']');
    if (closing_bracket == std::string::npos) {
      return false;
    }
    host = authority.substr(1, closing_bracket - 1);
  } else {
    const size_t port_separator = authority.find(':');
    host = authority.substr(0, port_separator);
  }
  if (host.empty()) {
    return false;
  }

  if (host_out != nullptr) {
    *host_out = ToLowerAscii(host);
  }
  if (secure_out != nullptr) {
    *secure_out = scheme == "https";
  }
  return true;
}

bool ContainsImmichAuthCookie(const std::string& cookie_header) {
  const std::string lowered = ToLowerAscii(cookie_header);
  return lowered.find("immich_access_token=") != std::string::npos ||
      lowered.find("immich_is_authenticated=") != std::string::npos ||
      lowered.find("immich_auth_type=") != std::string::npos;
}

std::string BuildImmichAuthCookie(const SessionState& session, const std::string& request_url) {
  if (session.access_token.empty() || session.server_urls.empty()) {
    return std::string();
  }

  std::string request_host;
  if (!ParseUrlHostAndSecurity(request_url, &request_host, nullptr)) {
    return std::string();
  }

  for (const std::string& server_url : session.server_urls) {
    std::string server_host;
    if (!ParseUrlHostAndSecurity(server_url, &server_host, nullptr)) {
      continue;
    }
    if (server_host == request_host) {
      return "immich_access_token=" + session.access_token + "; immich_is_authenticated=true; immich_auth_type=password";
    }
  }

  return std::string();
}

void MergeSessionHeaders(
    const SessionState& session,
    const std::string& request_url,
    std::vector<std::pair<std::string, std::string>>* headers) {
  if (headers == nullptr) {
    return;
  }

  for (const auto& entry : session.request_headers) {
    if (FindHeaderIndex(*headers, entry.first.c_str()) < 0) {
      headers->push_back(entry);
    }
  }

  const std::string auth_cookie = BuildImmichAuthCookie(session, request_url);
  if (auth_cookie.empty()) {
    return;
  }

  const int cookie_index = FindHeaderIndex(*headers, "Cookie");
  if (cookie_index >= 0) {
    if (!ContainsImmichAuthCookie((*headers)[cookie_index].second)) {
      if (!(*headers)[cookie_index].second.empty()) {
        (*headers)[cookie_index].second += "; ";
      }
      (*headers)[cookie_index].second += auth_cookie;
    }
    return;
  }

  headers->push_back(std::make_pair(std::string("Cookie"), auth_cookie));
}

SessionState CopySessionState() {
  std::lock_guard<std::mutex> lock(g_session_mutex);
  return g_session_state;
}

int32_t UpdateRequestState(const std::string& headers_json, const std::string& server_urls_json, const std::string& token) {
  const std::string effective_headers_json = headers_json.empty() ? "{}" : headers_json;
  const std::string effective_server_urls_json = server_urls_json.empty() ? "[]" : server_urls_json;

  std::vector<std::pair<std::string, std::string>> parsed_headers;
  if (effective_headers_json != "{}") {
    std::string parse_error;
    if (!ParseJsonHeaderObject(effective_headers_json, &parsed_headers, &parse_error)) {
      return kConfigParseFailed;
    }
  }

  std::vector<std::string> parsed_server_urls;
  if (effective_server_urls_json != "[]") {
    std::string parse_error;
    if (!ParseJsonStringArray(effective_server_urls_json, &parsed_server_urls, &parse_error)) {
      return kConfigParseFailed;
    }
  }

  SessionState updated_state;
  for (const auto& header : parsed_headers) {
    updated_state.request_headers[header.first] = header.second;
  }
  updated_state.server_urls = parsed_server_urls;
  updated_state.access_token = token;

  {
    std::lock_guard<std::mutex> lock(g_session_mutex);
    g_session_state.request_headers = updated_state.request_headers;
    g_session_state.server_urls = updated_state.server_urls;
    g_session_state.access_token = updated_state.access_token;
  }
  return kDispatchOk;
}

int32_t UpdateClientCertificateState(
    const std::string& cert_path,
    const std::string& key_path,
    const std::string& cert_type,
    const std::string& key_password) {
  std::lock_guard<std::mutex> lock(g_session_mutex);
  if (cert_path.empty()) {
    g_session_state.cert_path.clear();
    g_session_state.key_path.clear();
    g_session_state.cert_type.clear();
    g_session_state.key_password.clear();
    return kDispatchOk;
  }

  g_session_state.cert_path = cert_path;
  g_session_state.key_path = key_path.empty() ? cert_path : key_path;
  g_session_state.cert_type = cert_type.empty() ? "P12" : cert_type;
  g_session_state.key_password = key_password;
  return kDispatchOk;
}

int32_t UpdateCaBundlePath(const std::string& ca_bundle_path) {
  std::lock_guard<std::mutex> lock(g_session_mutex);
  if (ca_bundle_path.empty()) {
    g_session_state.ca_bundle_path.clear();
  } else {
    g_session_state.ca_bundle_path = ca_bundle_path;
  }
  return kDispatchOk;
}

#ifdef IMMICH_OHOS_HAS_LIBCURL
void FreePkcs12ParseOutputs(EVP_PKEY* private_key, X509* certificate, STACK_OF_X509* ca_certificates) {
  if (private_key != nullptr) {
    EVP_PKEY_free(private_key);
  }
  if (certificate != nullptr) {
    X509_free(certificate);
  }
  if (ca_certificates == nullptr) {
    return;
  }

  OPENSSL_STACK* stack = reinterpret_cast<OPENSSL_STACK*>(ca_certificates);
  const int count = OPENSSL_sk_num(stack);
  for (int index = 0; index < count; ++index) {
    X509* ca_certificate = static_cast<X509*>(OPENSSL_sk_value(stack, index));
    if (ca_certificate != nullptr) {
      X509_free(ca_certificate);
    }
  }
  OPENSSL_sk_free(stack);
}

int32_t ExtractCaBundleFromPkcs12File(
    const std::string& pkcs12_path,
    const std::string& password,
    const std::string& output_path) {
  if (pkcs12_path.empty() || output_path.empty()) {
    return kDispatchInvalidArgument;
  }

  std::remove(output_path.c_str());

  BIO* input = BIO_new_file(pkcs12_path.c_str(), "rb");
  if (input == nullptr) {
    return kCertificateExtractionFailed;
  }

  PKCS12* pkcs12 = d2i_PKCS12_bio(input, nullptr);
  BIO_free(input);
  if (pkcs12 == nullptr) {
    return kCertificateExtractionFailed;
  }

  EVP_PKEY* private_key = nullptr;
  X509* certificate = nullptr;
  STACK_OF_X509* ca_certificates = nullptr;
  const int parsed = PKCS12_parse(
      pkcs12,
      password.empty() ? "" : password.c_str(),
      &private_key,
      &certificate,
      &ca_certificates);
  PKCS12_free(pkcs12);
  if (parsed != 1) {
    FreePkcs12ParseOutputs(private_key, certificate, ca_certificates);
    return kCertificateExtractionFailed;
  }

  OPENSSL_STACK* stack = reinterpret_cast<OPENSSL_STACK*>(ca_certificates);
  const int ca_count = stack != nullptr ? OPENSSL_sk_num(stack) : 0;
  if (certificate == nullptr && ca_count <= 0) {
    FreePkcs12ParseOutputs(private_key, certificate, ca_certificates);
    return kCertificateNoCaBundle;
  }

  BIO* output = BIO_new_file(output_path.c_str(), "wb");
  if (output == nullptr) {
    FreePkcs12ParseOutputs(private_key, certificate, ca_certificates);
    return kCertificateExtractionFailed;
  }

  int written_count = 0;
  if (certificate != nullptr && PEM_write_bio_X509(output, certificate) == 1) {
    ++written_count;
  }
  for (int index = 0; index < ca_count; ++index) {
    X509* ca_certificate = static_cast<X509*>(OPENSSL_sk_value(stack, index));
    if (ca_certificate != nullptr && PEM_write_bio_X509(output, ca_certificate) == 1) {
      ++written_count;
    }
  }
  BIO_free(output);
  FreePkcs12ParseOutputs(private_key, certificate, ca_certificates);

  if (written_count <= 0) {
    std::remove(output_path.c_str());
    return kCertificateExtractionFailed;
  }

  return kDispatchOk;
}
#else
int32_t ExtractCaBundleFromPkcs12File(
    const std::string& pkcs12_path,
    const std::string& password,
    const std::string& output_path) {
  (void)pkcs12_path;
  (void)password;
  (void)output_path;
  return kCertificateExtractionFailed;
}
#endif

void RegisterStreamRequest(const std::shared_ptr<StreamRequestTask>& task) {
  if (!task) {
    return;
  }

  std::lock_guard<std::mutex> lock(g_stream_mutex);
  g_stream_requests[task->request_id] = task;
}

void UnregisterStreamRequest(int64_t request_id) {
  std::lock_guard<std::mutex> lock(g_stream_mutex);
  g_stream_requests.erase(request_id);
}

bool CancelStreamRequest(int64_t request_id) {
  std::shared_ptr<StreamRequestTask> task;
  {
    std::lock_guard<std::mutex> lock(g_stream_mutex);
    const auto it = g_stream_requests.find(request_id);
    if (it == g_stream_requests.end()) {
      return false;
    }
    task = it->second;
  }

  if (!task) {
    return false;
  }

  task->cancelled.store(true);
  return true;
}

void RegisterMultipartRequest(const std::shared_ptr<MultipartRequestTask>& task) {
  if (!task) {
    return;
  }

  std::lock_guard<std::mutex> lock(g_multipart_mutex);
  g_multipart_requests[task->request_id] = task;
}

void UnregisterMultipartRequest(int64_t request_id) {
  std::lock_guard<std::mutex> lock(g_multipart_mutex);
  g_multipart_requests.erase(request_id);
}

bool CancelMultipartRequest(int64_t request_id) {
  std::shared_ptr<MultipartRequestTask> task;
  {
    std::lock_guard<std::mutex> lock(g_multipart_mutex);
    const auto it = g_multipart_requests.find(request_id);
    if (it == g_multipart_requests.end()) {
      return false;
    }
    task = it->second;
  }

  if (!task) {
    return false;
  }

  task->cancelled.store(true);
  return true;
}

std::string NormalizeMethod(const std::string& method) {
  std::string upper = method;
  for (char& ch : upper) {
    ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
  }
  return upper;
}

size_t CurlWriteCallback(char* contents, size_t size, size_t count, void* user_data) {
  const size_t total_size = size * count;
  if (total_size == 0) {
    return 0;
  }
  auto* response = static_cast<CurlResponse*>(user_data);
  response->body.insert(response->body.end(), contents, contents + total_size);
  return total_size;
}

size_t CurlHeaderCallback(char* contents, size_t size, size_t count, void* user_data) {
  const size_t total_size = size * count;
  if (total_size == 0) {
    return 0;
  }

  auto* response = static_cast<CurlResponse*>(user_data);
  std::string line(contents, total_size);
  if (line.rfind("HTTP/", 0) == 0) {
    response->headers.clear();
    response->headers_sent = false;
    long status_code = 0;
    if (ParseHttpStatusCode(line, &status_code)) {
      response->status_code = status_code;
    } else {
      response->status_code = 0;
    }
    return total_size;
  }

  line = TrimAsciiWhitespace(line);
  if (line.empty()) {
    return total_size;
  }

  const size_t separator_index = line.find(':');
  if (separator_index == std::string::npos) {
    return total_size;
  }

  const std::string key = TrimAsciiWhitespace(line.substr(0, separator_index));
  const std::string value = TrimAsciiWhitespace(line.substr(separator_index + 1));
  if (key.empty()) {
    return total_size;
  }

  auto existing = response->headers.find(key);
  if (existing == response->headers.end()) {
    response->headers[key] = value;
  } else if (!value.empty()) {
    if (!existing->second.empty()) {
      existing->second += ", ";
    }
    existing->second += value;
  }

  return total_size;
}

size_t CurlStreamWriteCallback(char* contents, size_t size, size_t count, void* user_data) {
  const size_t total_size = size * count;
  if (total_size == 0) {
    return 0;
  }

  auto* response = static_cast<CurlResponse*>(user_data);
  if (!MaybePostStreamHeaders(response)) {
    return 0;
  }
  if (!PostStreamChunkToDart(
          response->dart_port,
          response->request_id,
          reinterpret_cast<const uint8_t*>(contents),
          static_cast<intptr_t>(total_size))) {
    return 0;
  }
  return total_size;
}

int CurlStreamProgressCallback(
    void* client_data,
    curl_off_t download_total,
    curl_off_t download_now,
    curl_off_t upload_total,
    curl_off_t upload_now) {
  static_cast<void>(download_total);
  static_cast<void>(download_now);
  static_cast<void>(upload_total);
  static_cast<void>(upload_now);

  auto* task = static_cast<StreamRequestTask*>(client_data);
  if (task == nullptr) {
    return 0;
  }
  return task->cancelled.load() ? 1 : 0;
}

int CurlMultipartProgressCallback(
    void* client_data,
    curl_off_t download_total,
    curl_off_t download_now,
    curl_off_t upload_total,
    curl_off_t upload_now) {
  static_cast<void>(download_total);
  static_cast<void>(download_now);

  auto* task = static_cast<MultipartRequestTask*>(client_data);
  if (task == nullptr) {
    return 0;
  }

  if (task->cancelled.load()) {
    return 1;
  }

  const int64_t bytes_sent = static_cast<int64_t>(upload_now);
  const int64_t total_bytes = static_cast<int64_t>(upload_total);
  if (task->last_uploaded_bytes.load() == bytes_sent && task->last_total_bytes.load() == total_bytes) {
    return 0;
  }

  task->last_uploaded_bytes.store(bytes_sent);
  task->last_total_bytes.store(total_bytes);
  PostMultipartProgressToDart(task->dart_port, task->request_id, bytes_sent, total_bytes);
  return 0;
}

void EnsureCurlInitialized() {
  g_curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

bool HasCurlSupport(std::string* error) {
  std::call_once(g_curl_init_once, EnsureCurlInitialized);
  if (g_curl_init_result == CURLE_OK) {
    return true;
  }
  if (error != nullptr) {
    *error = curl_easy_strerror(g_curl_init_result);
  }
  return false;
}

void PerformCurlRequest(std::unique_ptr<RequestTask> task) {
  if (!task) {
    return;
  }

  std::string curl_error_message;
  if (!HasCurlSupport(&curl_error_message)) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_INIT_FAILED", curl_error_message);
    return;
  }

  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> handle(curl_easy_init(), &curl_easy_cleanup);
  if (!handle) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_INIT_FAILED", "Failed to create a libcurl easy handle.");
    return;
  }

  CurlResponse response;
  std::vector<std::pair<std::string, std::string>> parsed_headers;
  if (!task->headers_json.empty() && task->headers_json != "{}") {
    std::string header_parse_error;
    if (!ParseJsonHeaderObject(task->headers_json, &parsed_headers, &header_parse_error)) {
      PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_HEADERS_INVALID", header_parse_error);
      return;
    }
  }

  const SessionState session = CopySessionState();
  MergeSessionHeaders(session, task->url, &parsed_headers);
  const bool skip_remote_validation = ConsumeRemoteValidationSkip(&parsed_headers);
  bool is_secure_request = false;
  ParseUrlHostAndSecurity(task->url, nullptr, &is_secure_request);

  curl_slist* raw_headers = nullptr;
  for (const auto& header : parsed_headers) {
    if (header.first.empty()) {
      continue;
    }
    const std::string header_line = header.first + ": " + header.second;
    raw_headers = curl_slist_append(raw_headers, header_line.c_str());
  }
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> request_headers(raw_headers, &curl_slist_free_all);

  char error_buffer[CURL_ERROR_SIZE] = {0};
  std::string setopt_error;
  if (!SetCurlOption(handle.get(), CURLOPT_ERRORBUFFER, "CURLOPT_ERRORBUFFER", error_buffer, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_NOSIGNAL, "CURLOPT_NOSIGNAL", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_FOLLOWLOCATION, "CURLOPT_FOLLOWLOCATION", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_MAXREDIRS, "CURLOPT_MAXREDIRS", 10L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_ACCEPT_ENCODING, "CURLOPT_ACCEPT_ENCODING", "", &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_URL, "CURLOPT_URL", task->url.c_str(), &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEFUNCTION, "CURLOPT_WRITEFUNCTION", CurlWriteCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEDATA, "CURLOPT_WRITEDATA", &response, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERFUNCTION, "CURLOPT_HEADERFUNCTION", CurlHeaderCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERDATA, "CURLOPT_HEADERDATA", &response, &setopt_error)) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    return;
  }

  if (!ApplyCurlSslOptions(handle.get(), session, skip_remote_validation, is_secure_request, &setopt_error)) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    return;
  }

  if (request_headers) {
    if (!SetCurlOption(handle.get(), CURLOPT_HTTPHEADER, "CURLOPT_HTTPHEADER", request_headers.get(), &setopt_error)) {
      PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }

  if (task->connect_timeout_ms > 0) {
    if (!SetCurlOption(
            handle.get(),
            CURLOPT_CONNECTTIMEOUT_MS,
            "CURLOPT_CONNECTTIMEOUT_MS",
            static_cast<long>(task->connect_timeout_ms),
            &setopt_error)) {
      PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }
  if (task->read_timeout_ms > 0) {
    const long total_timeout_ms = task->connect_timeout_ms > 0
        ? static_cast<long>(task->connect_timeout_ms) + static_cast<long>(task->read_timeout_ms)
        : static_cast<long>(task->read_timeout_ms);
    if (!SetCurlOption(handle.get(), CURLOPT_TIMEOUT_MS, "CURLOPT_TIMEOUT_MS", total_timeout_ms, &setopt_error)) {
      PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }

  const std::string method = NormalizeMethod(task->method);
  if (!ApplyCurlMethodAndBody(handle.get(), method, task->body, &setopt_error)) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    return;
  }

  const CURLcode perform_result = curl_easy_perform(handle.get());
  if (perform_result != CURLE_OK) {
    std::string message = error_buffer[0] != '\0' ? error_buffer : curl_easy_strerror(perform_result);
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_CURL_ERROR", message);
    return;
  }

  curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &response.status_code);
  const std::string headers_json = SerializeHeadersJson(response.headers);
  PostSuccessToDart(
      task->dart_port,
      task->request_id,
      static_cast<int32_t>(response.status_code),
      headers_json,
      response.body.empty() ? nullptr : response.body.data(),
      static_cast<intptr_t>(response.body.size()));
}

void PerformCurlStreamRequest(const std::shared_ptr<StreamRequestTask>& task) {
  if (!task) {
    return;
  }

  const int64_t request_id = task->request_id;
  const int64_t dart_port = task->dart_port;

  std::string curl_error_message;
  if (!HasCurlSupport(&curl_error_message)) {
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_INIT_FAILED", curl_error_message);
    UnregisterStreamRequest(request_id);
    return;
  }

  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> handle(curl_easy_init(), &curl_easy_cleanup);
  if (!handle) {
    PostStreamErrorToDart(
        dart_port,
        request_id,
        "HTTP_FFI_CURL_INIT_FAILED",
        "Failed to create a libcurl easy handle.");
    UnregisterStreamRequest(request_id);
    return;
  }

  CurlResponse response;
  response.dart_port = dart_port;
  response.request_id = request_id;

  std::vector<std::pair<std::string, std::string>> parsed_headers;
  if (!task->headers_json.empty() && task->headers_json != "{}") {
    std::string header_parse_error;
    if (!ParseJsonHeaderObject(task->headers_json, &parsed_headers, &header_parse_error)) {
      PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_HEADERS_INVALID", header_parse_error);
      UnregisterStreamRequest(request_id);
      return;
    }
  }

  const SessionState session = CopySessionState();
  MergeSessionHeaders(session, task->url, &parsed_headers);
  const bool skip_remote_validation = ConsumeRemoteValidationSkip(&parsed_headers);
  bool is_secure_request = false;
  ParseUrlHostAndSecurity(task->url, nullptr, &is_secure_request);

  curl_slist* raw_headers = nullptr;
  for (const auto& header : parsed_headers) {
    if (header.first.empty()) {
      continue;
    }
    const std::string header_line = header.first + ": " + header.second;
    raw_headers = curl_slist_append(raw_headers, header_line.c_str());
  }
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> request_headers(raw_headers, &curl_slist_free_all);

  char error_buffer[CURL_ERROR_SIZE] = {0};
  std::string setopt_error;
  if (!SetCurlOption(handle.get(), CURLOPT_ERRORBUFFER, "CURLOPT_ERRORBUFFER", error_buffer, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_NOSIGNAL, "CURLOPT_NOSIGNAL", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_FOLLOWLOCATION, "CURLOPT_FOLLOWLOCATION", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_MAXREDIRS, "CURLOPT_MAXREDIRS", 10L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_ACCEPT_ENCODING, "CURLOPT_ACCEPT_ENCODING", "", &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_URL, "CURLOPT_URL", task->url.c_str(), &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEFUNCTION, "CURLOPT_WRITEFUNCTION", CurlStreamWriteCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEDATA, "CURLOPT_WRITEDATA", &response, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERFUNCTION, "CURLOPT_HEADERFUNCTION", CurlHeaderCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERDATA, "CURLOPT_HEADERDATA", &response, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_NOPROGRESS, "CURLOPT_NOPROGRESS", 0L, &setopt_error) ||
      !SetCurlOption(
          handle.get(),
          CURLOPT_XFERINFOFUNCTION,
          "CURLOPT_XFERINFOFUNCTION",
          CurlStreamProgressCallback,
          &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_XFERINFODATA, "CURLOPT_XFERINFODATA", task.get(), &setopt_error)) {
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    UnregisterStreamRequest(request_id);
    return;
  }

  if (!ApplyCurlSslOptions(handle.get(), session, skip_remote_validation, is_secure_request, &setopt_error)) {
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    UnregisterStreamRequest(request_id);
    return;
  }

  if (request_headers) {
    if (!SetCurlOption(handle.get(), CURLOPT_HTTPHEADER, "CURLOPT_HTTPHEADER", request_headers.get(), &setopt_error)) {
      PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      UnregisterStreamRequest(request_id);
      return;
    }
  }

  if (task->connect_timeout_ms > 0) {
    if (!SetCurlOption(
            handle.get(),
            CURLOPT_CONNECTTIMEOUT_MS,
            "CURLOPT_CONNECTTIMEOUT_MS",
            static_cast<long>(task->connect_timeout_ms),
            &setopt_error)) {
      PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      UnregisterStreamRequest(request_id);
      return;
    }
  }
  if (task->read_timeout_ms > 0) {
    long low_speed_time = static_cast<long>((task->read_timeout_ms + 999) / 1000);
    if (low_speed_time < 1) {
      low_speed_time = 1;
    }
    if (!SetCurlOption(handle.get(), CURLOPT_LOW_SPEED_LIMIT, "CURLOPT_LOW_SPEED_LIMIT", 1L, &setopt_error) ||
        !SetCurlOption(handle.get(), CURLOPT_LOW_SPEED_TIME, "CURLOPT_LOW_SPEED_TIME", low_speed_time, &setopt_error)) {
      PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      UnregisterStreamRequest(request_id);
      return;
    }
  }

  const std::string method = NormalizeMethod(task->method);
  if (!ApplyCurlMethodAndBody(handle.get(), method, task->body, &setopt_error)) {
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    UnregisterStreamRequest(request_id);
    return;
  }

  const CURLcode perform_result = curl_easy_perform(handle.get());
  if (perform_result != CURLE_OK) {
    if (perform_result == CURLE_ABORTED_BY_CALLBACK && task->cancelled.load()) {
      UnregisterStreamRequest(request_id);
      return;
    }

    std::string message = error_buffer[0] != '\0' ? error_buffer : curl_easy_strerror(perform_result);
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_CURL_ERROR", message);
    UnregisterStreamRequest(request_id);
    return;
  }

  curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &response.status_code);
  if (!MaybePostStreamHeaders(&response)) {
    UnregisterStreamRequest(request_id);
    return;
  }
  PostStreamCompleteToDart(dart_port, request_id, static_cast<int32_t>(response.status_code));
  UnregisterStreamRequest(request_id);
}

void PerformCurlMultipartRequest(const std::shared_ptr<MultipartRequestTask>& task) {
  if (!task) {
    return;
  }

  const int64_t request_id = task->request_id;
  const int64_t dart_port = task->dart_port;
  const auto fail_request = [&](const std::string& code, const std::string& message) {
    PostFailureToDart(dart_port, request_id, code, message);
    UnregisterMultipartRequest(request_id);
  };

  std::string curl_error_message;
  if (!HasCurlSupport(&curl_error_message)) {
    fail_request("HTTP_FFI_CURL_INIT_FAILED", curl_error_message);
    return;
  }

  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> handle(curl_easy_init(), &curl_easy_cleanup);
  if (!handle) {
    fail_request("HTTP_FFI_CURL_INIT_FAILED", "Failed to create a libcurl easy handle.");
    return;
  }

  CurlResponse response;
  std::vector<std::pair<std::string, std::string>> parsed_headers;
  if (!task->headers_json.empty() && task->headers_json != "{}") {
    std::string header_parse_error;
    if (!ParseJsonHeaderObject(task->headers_json, &parsed_headers, &header_parse_error)) {
      fail_request("HTTP_FFI_HEADERS_INVALID", header_parse_error);
      return;
    }
  }

  std::vector<std::pair<std::string, std::string>> parsed_fields;
  if (!task->fields_json.empty() && task->fields_json != "{}") {
    std::string fields_parse_error;
    if (!ParseJsonHeaderObject(task->fields_json, &parsed_fields, &fields_parse_error)) {
      fail_request("HTTP_FFI_FIELDS_INVALID", fields_parse_error);
      return;
    }
  }

  std::vector<MultipartFilePart> parsed_files;
  if (!task->files_json.empty() && task->files_json != "[]") {
    std::string files_parse_error;
    if (!ParseJsonMultipartFilesArray(task->files_json, &parsed_files, &files_parse_error)) {
      fail_request("HTTP_FFI_FILES_INVALID", files_parse_error);
      return;
    }
  }
  if (parsed_files.empty()) {
    fail_request("HTTP_FFI_MULTIPART_FILE_MISSING", "Multipart upload requires at least one file part.");
    return;
  }

  RemoveHeader(&parsed_headers, "Content-Type");
  RemoveHeader(&parsed_headers, "Content-Length");

  const SessionState session = CopySessionState();
  MergeSessionHeaders(session, task->url, &parsed_headers);
  const bool skip_remote_validation = ConsumeRemoteValidationSkip(&parsed_headers);
  bool is_secure_request = false;
  ParseUrlHostAndSecurity(task->url, nullptr, &is_secure_request);

  curl_slist* raw_headers = nullptr;
  for (const auto& header : parsed_headers) {
    if (header.first.empty()) {
      continue;
    }
    const std::string header_line = header.first + ": " + header.second;
    raw_headers = curl_slist_append(raw_headers, header_line.c_str());
  }
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> request_headers(raw_headers, &curl_slist_free_all);

  std::unique_ptr<curl_mime, decltype(&curl_mime_free)> mime(curl_mime_init(handle.get()), &curl_mime_free);
  if (!mime) {
    fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to create a libcurl MIME payload.");
    return;
  }

  for (const auto& field : parsed_fields) {
    if (field.first.empty()) {
      continue;
    }

    curl_mimepart* field_part = curl_mime_addpart(mime.get());
    if (field_part == nullptr) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to create a multipart form field.");
      return;
    }
    if (curl_mime_name(field_part, field.first.c_str()) != CURLE_OK ||
        curl_mime_data(field_part, field.second.c_str(), CURL_ZERO_TERMINATED) != CURLE_OK) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to configure a multipart form field.");
      return;
    }
  }

  std::vector<std::unique_ptr<FILE, int (*)(FILE*)>> upload_files;
  std::vector<CurlMultipartFileSource> upload_file_sources;
  upload_files.reserve(parsed_files.size());
  upload_file_sources.reserve(parsed_files.size());

  for (const auto& file : parsed_files) {
    struct stat upload_file_stat {};
    if (stat(file.file_path.c_str(), &upload_file_stat) != 0) {
      fail_request(
          "HTTP_FFI_MULTIPART_FILE_NOT_FOUND",
          std::string("File does not exist: ") + file.file_path + " (" + std::strerror(errno) + ")");
      return;
    }
    if (!S_ISREG(upload_file_stat.st_mode)) {
      fail_request("HTTP_FFI_MULTIPART_NOT_A_FILE", std::string("Not a regular file: ") + file.file_path);
      return;
    }

    std::unique_ptr<FILE, int (*)(FILE*)> upload_file(std::fopen(file.file_path.c_str(), "rb"), &std::fclose);
    if (!upload_file) {
      fail_request(
          "HTTP_FFI_MULTIPART_FILE_OPEN_FAILED",
          std::string("Failed to open file: ") + file.file_path + " (" + std::strerror(errno) + ")");
      return;
    }
    upload_file_sources.push_back(CurlMultipartFileSource{upload_file.get()});
    CurlMultipartFileSource& upload_file_source = upload_file_sources.back();
    upload_files.push_back(std::move(upload_file));
    const curl_off_t upload_file_size = static_cast<curl_off_t>(upload_file_stat.st_size);

    curl_mimepart* file_part = curl_mime_addpart(mime.get());
    if (file_part == nullptr) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to create a multipart file part.");
      return;
    }
    if (curl_mime_name(file_part, file.field_name.c_str()) != CURLE_OK ||
        curl_mime_data_cb(
            file_part,
            upload_file_size,
            CurlMultipartFileReadCallback,
            CurlMultipartFileSeekCallback,
            nullptr,
            &upload_file_source) != CURLE_OK) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to configure a multipart file part.");
      return;
    }
    if (!file.file_name.empty() && curl_mime_filename(file_part, file.file_name.c_str()) != CURLE_OK) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to set a multipart filename.");
      return;
    }
    if (!file.content_type.empty() && curl_mime_type(file_part, file.content_type.c_str()) != CURLE_OK) {
      fail_request("HTTP_FFI_MULTIPART_INIT_FAILED", "Failed to set a multipart content type.");
      return;
    }
  }

  char error_buffer[CURL_ERROR_SIZE] = {0};
  std::string setopt_error;
  if (!SetCurlOption(handle.get(), CURLOPT_ERRORBUFFER, "CURLOPT_ERRORBUFFER", error_buffer, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_NOSIGNAL, "CURLOPT_NOSIGNAL", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_FOLLOWLOCATION, "CURLOPT_FOLLOWLOCATION", 1L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_MAXREDIRS, "CURLOPT_MAXREDIRS", 10L, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_ACCEPT_ENCODING, "CURLOPT_ACCEPT_ENCODING", "", &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_URL, "CURLOPT_URL", task->url.c_str(), &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEFUNCTION, "CURLOPT_WRITEFUNCTION", CurlWriteCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_WRITEDATA, "CURLOPT_WRITEDATA", &response, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERFUNCTION, "CURLOPT_HEADERFUNCTION", CurlHeaderCallback, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_HEADERDATA, "CURLOPT_HEADERDATA", &response, &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_NOPROGRESS, "CURLOPT_NOPROGRESS", 0L, &setopt_error) ||
      !SetCurlOption(
          handle.get(),
          CURLOPT_XFERINFOFUNCTION,
          "CURLOPT_XFERINFOFUNCTION",
          CurlMultipartProgressCallback,
          &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_XFERINFODATA, "CURLOPT_XFERINFODATA", task.get(), &setopt_error) ||
      !SetCurlOption(handle.get(), CURLOPT_MIMEPOST, "CURLOPT_MIMEPOST", mime.get(), &setopt_error)) {
    fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    return;
  }

  if (!ApplyCurlSslOptions(handle.get(), session, skip_remote_validation, is_secure_request, &setopt_error)) {
    fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
    return;
  }

  if (request_headers) {
    if (!SetCurlOption(handle.get(), CURLOPT_HTTPHEADER, "CURLOPT_HTTPHEADER", request_headers.get(), &setopt_error)) {
      fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }

  if (task->connect_timeout_ms > 0) {
    if (!SetCurlOption(
            handle.get(),
            CURLOPT_CONNECTTIMEOUT_MS,
            "CURLOPT_CONNECTTIMEOUT_MS",
            static_cast<long>(task->connect_timeout_ms),
            &setopt_error)) {
      fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }
  if (task->read_timeout_ms > 0) {
    long low_speed_time = static_cast<long>((task->read_timeout_ms + 999) / 1000);
    if (low_speed_time < 1) {
      low_speed_time = 1;
    }
    if (!SetCurlOption(handle.get(), CURLOPT_LOW_SPEED_LIMIT, "CURLOPT_LOW_SPEED_LIMIT", 1L, &setopt_error) ||
        !SetCurlOption(
            handle.get(), CURLOPT_LOW_SPEED_TIME, "CURLOPT_LOW_SPEED_TIME", low_speed_time, &setopt_error)) {
      fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }

  const std::string method = NormalizeMethod(task->method);
  if (method != "POST") {
    if (!SetCurlOption(handle.get(), CURLOPT_CUSTOMREQUEST, "CURLOPT_CUSTOMREQUEST", method.c_str(), &setopt_error)) {
      fail_request("HTTP_FFI_CURL_OPTION_FAILED", setopt_error);
      return;
    }
  }

  const CURLcode perform_result = curl_easy_perform(handle.get());
  if (perform_result != CURLE_OK) {
    if (perform_result == CURLE_ABORTED_BY_CALLBACK && task->cancelled.load()) {
      UnregisterMultipartRequest(request_id);
      return;
    }

    std::string message = error_buffer[0] != '\0' ? error_buffer : curl_easy_strerror(perform_result);
    fail_request("HTTP_FFI_CURL_ERROR", message);
    return;
  }

  curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &response.status_code);
  const std::string headers_json = SerializeHeadersJson(response.headers);
  PostSuccessToDart(
      dart_port,
      request_id,
      static_cast<int32_t>(response.status_code),
      headers_json,
      response.body.empty() ? nullptr : response.body.data(),
      static_cast<intptr_t>(response.body.size()));
  UnregisterMultipartRequest(request_id);
}
#endif

napi_value MakeInt32(napi_env env, int32_t value) {
  napi_value result;
  napi_create_int32(env, value, &result);
  return result;
}

napi_value ReturnUndefined(napi_env env) {
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

std::string GetString(napi_env env, napi_value value) {
  if (value == nullptr) {
    return std::string();
  }

  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return std::string();
  }

  std::string result(length, '\0');
  if (length == 0) {
    return result;
  }

  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, result.data(), length + 1, &copied) != napi_ok) {
    return std::string();
  }
  result.resize(copied);
  return result;
}

bool GetInt64Value(napi_env env, napi_value value, int64_t* out) {
  if (value == nullptr || out == nullptr) {
    return false;
  }
  return napi_get_value_int64(env, value, out) == napi_ok;
}

bool GetInt32Value(napi_env env, napi_value value, int32_t* out) {
  if (value == nullptr || out == nullptr) {
    return false;
  }
  return napi_get_value_int32(env, value, out) == napi_ok;
}

bool SetNamedProperty(napi_env env, napi_value object, const char* name, napi_value value) {
  return napi_set_named_property(env, object, name, value) == napi_ok;
}

bool PostFailureToDart(int64_t dart_port, int64_t request_id, const std::string& code, const std::string& message) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject ok_object;
  ok_object.type = Dart_CObject_kInt32;
  ok_object.value.as_int32 = 0;

  Dart_CObject code_object;
  code_object.type = Dart_CObject_kString;
  code_object.value.as_string = const_cast<char*>(code.c_str());

  Dart_CObject message_object;
  message_object.type = Dart_CObject_kString;
  message_object.value.as_string = const_cast<char*>(message.c_str());

  Dart_CObject* values[] = {
    &request_id_object,
    &ok_object,
    &code_object,
    &message_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostSuccessToDart(
    int64_t dart_port,
    int64_t request_id,
    int32_t status_code,
    const std::string& headers_json,
    const uint8_t* body,
    intptr_t body_length) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject ok_object;
  ok_object.type = Dart_CObject_kInt32;
  ok_object.value.as_int32 = 1;

  Dart_CObject status_code_object;
  status_code_object.type = Dart_CObject_kInt32;
  status_code_object.value.as_int32 = status_code;

  Dart_CObject headers_object;
  headers_object.type = Dart_CObject_kString;
  headers_object.value.as_string = const_cast<char*>(headers_json.c_str());

  Dart_CObject body_object;
  if (body != nullptr && body_length > 0) {
    body_object.type = Dart_CObject_kTypedData;
    body_object.value.as_typed_data.type = Dart_TypedData_kUint8;
    body_object.value.as_typed_data.length = body_length;
    body_object.value.as_typed_data.values = const_cast<uint8_t*>(body);
  } else {
    body_object.type = Dart_CObject_kNull;
  }

  Dart_CObject* values[] = {
    &request_id_object,
    &ok_object,
    &status_code_object,
    &headers_object,
    &body_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostStreamHeadersToDart(
    int64_t dart_port,
    int64_t request_id,
    int32_t status_code,
    const std::string& headers_json) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject tag_object;
  tag_object.type = Dart_CObject_kString;
  tag_object.value.as_string = const_cast<char*>("headers");

  Dart_CObject status_code_object;
  status_code_object.type = Dart_CObject_kInt32;
  status_code_object.value.as_int32 = status_code;

  Dart_CObject headers_object;
  headers_object.type = Dart_CObject_kString;
  headers_object.value.as_string = const_cast<char*>(headers_json.c_str());

  Dart_CObject* values[] = {
    &request_id_object,
    &tag_object,
    &status_code_object,
    &headers_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostStreamChunkToDart(int64_t dart_port, int64_t request_id, const uint8_t* chunk, intptr_t chunk_length) {
  if (dart_port == 0 || chunk == nullptr || chunk_length <= 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject tag_object;
  tag_object.type = Dart_CObject_kString;
  tag_object.value.as_string = const_cast<char*>("chunk");

  Dart_CObject chunk_object;
  chunk_object.type = Dart_CObject_kTypedData;
  chunk_object.value.as_typed_data.type = Dart_TypedData_kUint8;
  chunk_object.value.as_typed_data.length = chunk_length;
  chunk_object.value.as_typed_data.values = const_cast<uint8_t*>(chunk);

  Dart_CObject* values[] = {
    &request_id_object,
    &tag_object,
    &chunk_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostStreamCompleteToDart(int64_t dart_port, int64_t request_id, int32_t status_code) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject tag_object;
  tag_object.type = Dart_CObject_kString;
  tag_object.value.as_string = const_cast<char*>("complete");

  Dart_CObject status_code_object;
  status_code_object.type = Dart_CObject_kInt32;
  status_code_object.value.as_int32 = status_code;

  Dart_CObject* values[] = {
    &request_id_object,
    &tag_object,
    &status_code_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostStreamErrorToDart(int64_t dart_port, int64_t request_id, const std::string& code, const std::string& message) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject tag_object;
  tag_object.type = Dart_CObject_kString;
  tag_object.value.as_string = const_cast<char*>("error");

  Dart_CObject code_object;
  code_object.type = Dart_CObject_kString;
  code_object.value.as_string = const_cast<char*>(code.c_str());

  Dart_CObject message_object;
  message_object.type = Dart_CObject_kString;
  message_object.value.as_string = const_cast<char*>(message.c_str());

  Dart_CObject* values[] = {
    &request_id_object,
    &tag_object,
    &code_object,
    &message_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

bool PostMultipartProgressToDart(int64_t dart_port, int64_t request_id, int64_t bytes_sent, int64_t total_bytes) {
  if (dart_port == 0) {
    return false;
  }

  Dart_CObject request_id_object;
  request_id_object.type = Dart_CObject_kInt64;
  request_id_object.value.as_int64 = request_id;

  Dart_CObject tag_object;
  tag_object.type = Dart_CObject_kString;
  tag_object.value.as_string = const_cast<char*>("uploadProgress");

  Dart_CObject bytes_sent_object;
  bytes_sent_object.type = Dart_CObject_kInt64;
  bytes_sent_object.value.as_int64 = bytes_sent;

  Dart_CObject total_bytes_object;
  total_bytes_object.type = Dart_CObject_kInt64;
  total_bytes_object.value.as_int64 = total_bytes;

  Dart_CObject* values[] = {
    &request_id_object,
    &tag_object,
    &bytes_sent_object,
    &total_bytes_object,
  };

  Dart_CObject message_object_array;
  message_object_array.type = Dart_CObject_kArray;
  message_object_array.value.as_array.length = sizeof(values) / sizeof(values[0]);
  message_object_array.value.as_array.values = values;

  return Dart_PostCObject_DL(dart_port, &message_object_array);
}

void ResetDispatcherLocked() {
  if (g_dispatcher != nullptr) {
    napi_release_threadsafe_function(g_dispatcher, napi_tsfn_abort);
    g_dispatcher = nullptr;
  }
  g_bootstrap_state.fetch_and(~kDispatcherInstalled);
}

void FinalizeDispatcher(napi_env env, void* finalize_data, void* finalize_hint) {
  std::lock_guard<std::mutex> lock(g_dispatcher_mutex);
  g_dispatcher = nullptr;
  g_bootstrap_state.fetch_and(~kDispatcherInstalled);
}

void CallRequestDispatcher(napi_env env, napi_value js_callback, void* context, void* data) {
  std::unique_ptr<RequestTask> task(static_cast<RequestTask*>(data));
  if (!task) {
    return;
  }

  if (env == nullptr || js_callback == nullptr) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_DISPATCHER_UNAVAILABLE", "Dispatcher became unavailable.");
    return;
  }

  napi_value request_object;
  if (napi_create_object(env, &request_object) != napi_ok) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_REQUEST_OBJECT_FAILED", "Failed to create request object.");
    return;
  }

  napi_value request_id_value;
  napi_create_int64(env, task->request_id, &request_id_value);
  SetNamedProperty(env, request_object, "requestId", request_id_value);

  napi_value dart_port_value;
  napi_create_int64(env, task->dart_port, &dart_port_value);
  SetNamedProperty(env, request_object, "dartPort", dart_port_value);

  napi_value method_value;
  napi_create_string_utf8(env, task->method.c_str(), NAPI_AUTO_LENGTH, &method_value);
  SetNamedProperty(env, request_object, "method", method_value);

  napi_value url_value;
  napi_create_string_utf8(env, task->url.c_str(), NAPI_AUTO_LENGTH, &url_value);
  SetNamedProperty(env, request_object, "url", url_value);

  napi_value headers_value;
  napi_create_string_utf8(env, task->headers_json.c_str(), NAPI_AUTO_LENGTH, &headers_value);
  SetNamedProperty(env, request_object, "headersJson", headers_value);

  napi_value connect_timeout_value;
  napi_create_int32(env, task->connect_timeout_ms, &connect_timeout_value);
  SetNamedProperty(env, request_object, "connectTimeoutMs", connect_timeout_value);

  napi_value read_timeout_value;
  napi_create_int32(env, task->read_timeout_ms, &read_timeout_value);
  SetNamedProperty(env, request_object, "readTimeoutMs", read_timeout_value);

  napi_value body_value;
  if (!task->body.empty()) {
    void* arraybuffer_data = nullptr;
    napi_value arraybuffer;
    napi_create_arraybuffer(env, task->body.size(), &arraybuffer_data, &arraybuffer);
    std::memcpy(arraybuffer_data, task->body.data(), task->body.size());
    napi_create_typedarray(env, napi_uint8_array, task->body.size(), arraybuffer, 0, &body_value);
  } else {
    napi_get_undefined(env, &body_value);
  }
  SetNamedProperty(env, request_object, "body", body_value);

  napi_value undefined_value;
  napi_get_undefined(env, &undefined_value);
  napi_value args[] = {request_object};
  if (napi_call_function(env, undefined_value, js_callback, 1, args, nullptr) != napi_ok) {
    PostFailureToDart(task->dart_port, task->request_id, "HTTP_FFI_JS_CALLBACK_FAILED", "Failed to invoke ArkTS request handler.");
  }
}

napi_value LibraryVersion(napi_env env, napi_callback_info info) {
  return MakeInt32(env, kLibraryVersion);
}

napi_value BootstrapState(napi_env env, napi_callback_info info) {
  return MakeInt32(env, g_bootstrap_state.load());
}

napi_value Ping(napi_env env, napi_callback_info info) {
  return MakeInt32(env, kPingValue);
}

napi_value InstallRequestDispatcher(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return ReturnUndefined(env);
  }

  napi_valuetype value_type = napi_undefined;
  if (napi_typeof(env, args[0], &value_type) != napi_ok || value_type != napi_function) {
    return ReturnUndefined(env);
  }

  napi_value resource_name;
  napi_create_string_utf8(env, "ohos_http_ffi_dispatcher", NAPI_AUTO_LENGTH, &resource_name);

  napi_threadsafe_function dispatcher = nullptr;
  if (napi_create_threadsafe_function(
          env,
          args[0],
          nullptr,
          resource_name,
          0,
          1,
          nullptr,
          FinalizeDispatcher,
          nullptr,
          CallRequestDispatcher,
          &dispatcher) != napi_ok) {
    return ReturnUndefined(env);
  }

  napi_unref_threadsafe_function(env, dispatcher);

  std::lock_guard<std::mutex> lock(g_dispatcher_mutex);
  ResetDispatcherLocked();
  g_dispatcher = dispatcher;
  g_bootstrap_state.fetch_or(kDispatcherInstalled);
  return ReturnUndefined(env);
}

napi_value CompleteRequest(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 4) {
    return ReturnUndefined(env);
  }

  int64_t request_id = 0;
  int64_t dart_port = 0;
  int32_t status_code = 0;
  GetInt64Value(env, args[0], &request_id);
  GetInt64Value(env, args[1], &dart_port);
  GetInt32Value(env, args[2], &status_code);
  const std::string headers_json = GetString(env, args[3]);

  uint8_t* body_data = nullptr;
  size_t body_length = 0;
  if (argc >= 5) {
    bool is_typedarray = false;
    napi_is_typedarray(env, args[4], &is_typedarray);
    if (is_typedarray) {
      napi_typedarray_type array_type;
      napi_value arraybuffer;
      size_t byte_offset = 0;
      napi_get_typedarray_info(env, args[4], &array_type, &body_length, reinterpret_cast<void**>(&body_data), &arraybuffer, &byte_offset);
    } else {
      bool is_arraybuffer = false;
      napi_is_arraybuffer(env, args[4], &is_arraybuffer);
      if (is_arraybuffer) {
        napi_get_arraybuffer_info(env, args[4], reinterpret_cast<void**>(&body_data), &body_length);
      }
    }
  }

  PostSuccessToDart(dart_port, request_id, status_code, headers_json, body_data, static_cast<intptr_t>(body_length));
  return ReturnUndefined(env);
}

napi_value FailRequest(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 4) {
    return ReturnUndefined(env);
  }

  int64_t request_id = 0;
  int64_t dart_port = 0;
  GetInt64Value(env, args[0], &request_id);
  GetInt64Value(env, args[1], &dart_port);
  const std::string code = GetString(env, args[2]);
  const std::string message = GetString(env, args[3]);

  PostFailureToDart(dart_port, request_id, code, message);
  return ReturnUndefined(env);
}

napi_value SetRequestState(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  const std::string headers_json = argc >= 1 ? GetString(env, args[0]) : std::string();
  const std::string server_urls_json = argc >= 2 ? GetString(env, args[1]) : std::string();
  const std::string token = argc >= 3 ? GetString(env, args[2]) : std::string();

  return MakeInt32(env, UpdateRequestState(headers_json, server_urls_json, token));
}

napi_value SetClientCertificate(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  const std::string cert_path = argc >= 1 ? GetString(env, args[0]) : std::string();
  const std::string key_path = argc >= 2 ? GetString(env, args[1]) : std::string();
  const std::string cert_type = argc >= 3 ? GetString(env, args[2]) : std::string();
  const std::string key_password = argc >= 4 ? GetString(env, args[3]) : std::string();

  return MakeInt32(env, UpdateClientCertificateState(cert_path, key_path, cert_type, key_password));
}

napi_value ClearClientCertificate(napi_env env, napi_callback_info info) {
  return MakeInt32(env, UpdateClientCertificateState("", "", "", ""));
}

napi_value SetCaBundlePath(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  const std::string ca_bundle_path = argc >= 1 ? GetString(env, args[0]) : std::string();
  return MakeInt32(env, UpdateCaBundlePath(ca_bundle_path));
}

napi_value ExtractCaBundleFromPkcs12(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  const std::string pkcs12_path = argc >= 1 ? GetString(env, args[0]) : std::string();
  const std::string password = argc >= 2 ? GetString(env, args[1]) : std::string();
  const std::string output_path = argc >= 3 ? GetString(env, args[2]) : std::string();

  return MakeInt32(env, ExtractCaBundleFromPkcs12File(pkcs12_path, password, output_path));
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
    {"libraryVersion", nullptr, LibraryVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"bootstrapState", nullptr, BootstrapState, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"ping", nullptr, Ping, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setRequestState", nullptr, SetRequestState, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setClientCertificate", nullptr, SetClientCertificate, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"clearClientCertificate", nullptr, ClearClientCertificate, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setCaBundlePath", nullptr, SetCaBundlePath, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"extractCaBundleFromPkcs12", nullptr, ExtractCaBundleFromPkcs12, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"installRequestDispatcher", nullptr, InstallRequestDispatcher, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"completeRequest", nullptr, CompleteRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"failRequest", nullptr, FailRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  return exports;
}

}  // namespace

extern "C" {

__attribute__((visibility("default"))) int32_t ohos_http_ffi_library_version() {
  return kLibraryVersion;
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_bootstrap_state() {
  return g_bootstrap_state.load();
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_ping() {
  return kPingValue;
}

__attribute__((visibility("default"))) intptr_t ohos_http_ffi_initialize_dart_api(void* data) {
  return Dart_InitializeApiDL(data);
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_set_request_state(
    const char* headers_json,
    const char* server_urls_json,
    const char* token) {
  return UpdateRequestState(
      headers_json != nullptr ? headers_json : "{}",
      server_urls_json != nullptr ? server_urls_json : "[]",
      token != nullptr ? token : "");
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_set_client_certificate(
    const char* cert_path,
    const char* key_path,
    const char* cert_type,
    const char* key_password) {
  return UpdateClientCertificateState(
      cert_path != nullptr ? cert_path : "",
      key_path != nullptr ? key_path : "",
      cert_type != nullptr ? cert_type : "",
      key_password != nullptr ? key_password : "");
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_clear_client_certificate() {
  return UpdateClientCertificateState("", "", "", "");
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_set_ca_bundle_path(const char* ca_bundle_path) {
  return UpdateCaBundlePath(ca_bundle_path != nullptr ? ca_bundle_path : "");
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_send_request_async(
    int64_t request_id,
    int64_t dart_port,
    const char* method,
    const char* url,
    const char* headers_json,
    const uint8_t* body,
    int32_t body_length,
    int32_t connect_timeout_ms,
    int32_t read_timeout_ms) {
  if (dart_port == 0 || method == nullptr || url == nullptr || headers_json == nullptr || body_length < 0) {
    return kDispatchInvalidArgument;
  }

  std::unique_ptr<RequestTask> task(new RequestTask{
      request_id,
      dart_port,
      method,
      url,
      headers_json,
      {},
      connect_timeout_ms,
      read_timeout_ms,
  });

  if (body != nullptr && body_length > 0) {
    task->body.assign(body, body + body_length);
  }

#ifdef IMMICH_OHOS_HAS_LIBCURL
  try {
    std::thread worker(PerformCurlRequest, std::move(task));
    worker.detach();
    return kDispatchOk;
  } catch (const std::exception& error) {
    PostFailureToDart(dart_port, request_id, "HTTP_FFI_THREAD_START_FAILED", error.what());
    return kDispatchQueueFailed;
  } catch (...) {
    PostFailureToDart(dart_port, request_id, "HTTP_FFI_THREAD_START_FAILED", "Failed to start the native request worker thread.");
    return kDispatchQueueFailed;
  }
#else
  napi_threadsafe_function dispatcher = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_dispatcher_mutex);
    dispatcher = g_dispatcher;
  }

  if (dispatcher == nullptr) {
    PostFailureToDart(dart_port, request_id, "HTTP_FFI_DISPATCHER_MISSING", "ArkTS request dispatcher is not installed.");
    return kDispatchMissingDispatcher;
  }

  const napi_status status = napi_call_threadsafe_function(dispatcher, task.get(), napi_tsfn_nonblocking);
  if (status != napi_ok) {
    PostFailureToDart(dart_port, request_id, "HTTP_FFI_DISPATCH_FAILED", "Failed to enqueue ArkTS request dispatch.");
    return kDispatchQueueFailed;
  }

  task.release();
  return kDispatchOk;
#endif
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_send_stream_request_async(
    int64_t request_id,
    int64_t dart_port,
    const char* method,
    const char* url,
    const char* headers_json,
    const uint8_t* body,
    int32_t body_length,
    int32_t connect_timeout_ms,
    int32_t read_timeout_ms) {
  if (dart_port == 0 || method == nullptr || url == nullptr || headers_json == nullptr || body_length < 0) {
    return kDispatchInvalidArgument;
  }

#ifdef IMMICH_OHOS_HAS_LIBCURL
  std::shared_ptr<StreamRequestTask> task = std::make_shared<StreamRequestTask>();
  task->request_id = request_id;
  task->dart_port = dart_port;
  task->method = method;
  task->url = url;
  task->headers_json = headers_json;
  task->connect_timeout_ms = connect_timeout_ms;
  task->read_timeout_ms = read_timeout_ms;

  if (body != nullptr && body_length > 0) {
    task->body.assign(body, body + body_length);
  }

  RegisterStreamRequest(task);
  try {
    std::thread worker(PerformCurlStreamRequest, task);
    worker.detach();
    return kDispatchOk;
  } catch (const std::exception& error) {
    UnregisterStreamRequest(request_id);
    PostStreamErrorToDart(dart_port, request_id, "HTTP_FFI_THREAD_START_FAILED", error.what());
    return kDispatchQueueFailed;
  } catch (...) {
    UnregisterStreamRequest(request_id);
    PostStreamErrorToDart(
        dart_port,
        request_id,
        "HTTP_FFI_THREAD_START_FAILED",
        "Failed to start the native request worker thread.");
    return kDispatchQueueFailed;
  }
#else
  return kDispatchMissingDispatcher;
#endif
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_cancel_stream_request(int64_t request_id) {
  if (request_id <= 0) {
    return kDispatchInvalidArgument;
  }

#ifdef IMMICH_OHOS_HAS_LIBCURL
  CancelStreamRequest(request_id);
  return kDispatchOk;
#else
  return kDispatchMissingDispatcher;
#endif
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_send_multipart_request_async(
    int64_t request_id,
    int64_t dart_port,
    const char* method,
    const char* url,
    const char* headers_json,
    const char* fields_json,
    const char* files_json,
    int32_t connect_timeout_ms,
    int32_t read_timeout_ms) {
  if (dart_port == 0 || method == nullptr || url == nullptr || headers_json == nullptr || fields_json == nullptr ||
      files_json == nullptr || std::strlen(files_json) == 0) {
    return kDispatchInvalidArgument;
  }

#ifdef IMMICH_OHOS_HAS_LIBCURL
  std::shared_ptr<MultipartRequestTask> task = std::make_shared<MultipartRequestTask>();
  task->request_id = request_id;
  task->dart_port = dart_port;
  task->method = method;
  task->url = url;
  task->headers_json = headers_json;
  task->fields_json = fields_json;
  task->files_json = files_json;
  task->connect_timeout_ms = connect_timeout_ms;
  task->read_timeout_ms = read_timeout_ms;

  RegisterMultipartRequest(task);
  try {
    std::thread worker(PerformCurlMultipartRequest, task);
    worker.detach();
    return kDispatchOk;
  } catch (const std::exception& error) {
    UnregisterMultipartRequest(request_id);
    PostFailureToDart(dart_port, request_id, "HTTP_FFI_THREAD_START_FAILED", error.what());
    return kDispatchQueueFailed;
  } catch (...) {
    UnregisterMultipartRequest(request_id);
    PostFailureToDart(
        dart_port,
        request_id,
        "HTTP_FFI_THREAD_START_FAILED",
        "Failed to start the native multipart worker thread.");
    return kDispatchQueueFailed;
  }
#else
  return kDispatchMissingDispatcher;
#endif
}

__attribute__((visibility("default"))) int32_t ohos_http_ffi_cancel_multipart_request(int64_t request_id) {
  if (request_id <= 0) {
    return kDispatchInvalidArgument;
  }

#ifdef IMMICH_OHOS_HAS_LIBCURL
  CancelMultipartRequest(request_id);
  return kDispatchOk;
#else
  return kDispatchMissingDispatcher;
#endif
}

static napi_module ohos_http_ffi_module = {
    1,
    0,
    nullptr,
    Init,
    "ohos_http_ffi",
    nullptr,
    {0},
};

static void RegisterOhosHttpFfiModule(void) __attribute__((constructor));
static void RegisterOhosHttpFfiModule(void) {
  napi_module_register(&ohos_http_ffi_module);
}

}
