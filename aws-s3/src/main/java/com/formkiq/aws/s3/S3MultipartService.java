/**
 * MIT License
 *
 * Copyright (c) 2018 - 2020 FormKiQ
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
package com.formkiq.aws.s3;

import java.util.List;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.AbortMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.CompletedMultipartUpload;
import software.amazon.awssdk.services.s3.model.CompletedPart;
import software.amazon.awssdk.services.s3.model.CompleteMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.CreateMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.CreateMultipartUploadResponse;

/**
 * Stateless S3 multipart upload service. Unlike {@link S3MultipartUploader}, this service holds no
 * in-memory state, making it safe for use in Lambda environments where each API call may be handled
 * by a different invocation. The caller is responsible for passing the uploadId on each call.
 */
public class S3MultipartService {

  /** {@link S3Client}. */
  private final S3Client s3;

  /**
   * constructor.
   *
   * @param builder {@link S3ConnectionBuilder}
   */
  public S3MultipartService(final S3ConnectionBuilder builder) {
    this.s3 = builder.build();
  }

  /**
   * Initiate a multipart upload.
   *
   * @param bucket {@link String}
   * @param key {@link String}
   * @param contentType {@link String}
   * @return {@link String} the uploadId
   */
  public String createMultipartUpload(final String bucket, final String key,
      final String contentType) {
    CreateMultipartUploadRequest.Builder requestBuilder =
        CreateMultipartUploadRequest.builder().bucket(bucket).key(key);

    if (contentType != null) {
      requestBuilder = requestBuilder.contentType(contentType);
    }

    CreateMultipartUploadResponse response = this.s3.createMultipartUpload(requestBuilder.build());
    return response.uploadId();
  }

  /**
   * Complete a multipart upload.
   *
   * @param bucket {@link String}
   * @param key {@link String}
   * @param uploadId {@link String}
   * @param completedParts {@link List} of {@link CompletedPart}
   */
  public void completeMultipartUpload(final String bucket, final String key,
      final String uploadId, final List<CompletedPart> completedParts) {
    CompletedMultipartUpload completedMultipartUpload =
        CompletedMultipartUpload.builder().parts(completedParts).build();

    CompleteMultipartUploadRequest request = CompleteMultipartUploadRequest.builder().bucket(bucket)
        .key(key).uploadId(uploadId).multipartUpload(completedMultipartUpload).build();

    this.s3.completeMultipartUpload(request);
  }

  /**
   * Abort a multipart upload.
   *
   * @param bucket {@link String}
   * @param key {@link String}
   * @param uploadId {@link String}
   */
  public void abortMultipartUpload(final String bucket, final String key, final String uploadId) {
    AbortMultipartUploadRequest request = AbortMultipartUploadRequest.builder().bucket(bucket)
        .key(key).uploadId(uploadId).build();

    this.s3.abortMultipartUpload(request);
  }
}
