import 'dart:async';

import 'package:http/http.dart' as http;

/// A multipart request that carries file path information for native OHOS
/// multipart upload.
///
/// When sent through [OhosHttpClient], the native side streams the file path
/// through libcurl, avoiding loading the entire file into memory.
class OhosMultipartRequest extends http.BaseRequest {
  OhosMultipartRequest(super.method, super.url);

  /// Text form fields.
  final Map<String, String> fields = {};

  /// File parts to upload.
  final List<OhosMultipartFile> files = [];

  /// Optional callback for upload progress.
  void Function(int bytesSent, int totalBytes)? onProgress;

  /// Optional future that, when completed, cancels the request.
  Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    // Body is handled natively; return empty stream.
    return http.ByteStream(const Stream.empty());
  }
}

/// Describes a file to be uploaded as part of a multipart request.
class OhosMultipartFile {
  const OhosMultipartFile({
    required this.field,
    required this.filePath,
    required this.filename,
    this.contentType = 'application/octet-stream',
  });

  final String field;
  final String filePath;
  final String filename;
  final String contentType;
}
