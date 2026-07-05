import 'package:flutter_test/flutter_test.dart';
import 'package:ohos_http/src/ohos_http_client.dart';
import 'package:ohos_http/src/ohos_multipart_request.dart';

void main() {
  test('maps every multipart file to an FFI file part', () {
    final files = <OhosMultipartFile>[
      const OhosMultipartFile(
        field: 'assetData',
        filePath: '/data/storage/el2/base/files/photo-1.jpg',
        filename: 'photo-1.jpg',
        contentType: 'image/jpeg',
      ),
      const OhosMultipartFile(
        field: 'sidecar',
        filePath: '/data/storage/el2/base/files/photo-1.xmp',
        filename: 'photo-1.xmp',
        contentType: 'application/rdf+xml',
      ),
    ];

    final parts = createOhosHttpFfiMultipartFileParts(files);

    expect(parts, hasLength(2));
    expect(parts[0].toJson(), <String, String>{
      'field': 'assetData',
      'filePath': '/data/storage/el2/base/files/photo-1.jpg',
      'fileName': 'photo-1.jpg',
      'contentType': 'image/jpeg',
    });
    expect(parts[1].toJson(), <String, String>{
      'field': 'sidecar',
      'filePath': '/data/storage/el2/base/files/photo-1.xmp',
      'fileName': 'photo-1.xmp',
      'contentType': 'application/rdf+xml',
    });
  });
}
