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
package com.formkiq.stacks.api.handler.documents;

import com.formkiq.aws.dynamodb.ApiAuthorization;
import com.formkiq.aws.dynamodb.ApiPermission;
import com.formkiq.aws.s3.S3MultipartService;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEvent;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEventUtil;
import com.formkiq.aws.services.lambda.ApiGatewayRequestHandler;
import com.formkiq.aws.services.lambda.ApiRequestHandlerResponse;
import com.formkiq.module.lambdaservices.AwsServiceCache;

import java.util.Optional;

import static com.formkiq.aws.dynamodb.SiteIdKeyGenerator.isDefaultSiteId;

/**
 * {@link ApiGatewayRequestHandler} for
 * DELETE "/documents/{documentId}/upload/multipart/{uploadId}".
 *
 * Aborts an in-progress multipart upload, releasing any parts already staged in S3.
 */
public class DocumentsUploadMultipartAbortRequestHandler
    implements ApiGatewayRequestHandler, ApiGatewayRequestEventUtil {

  /** constructor. */
  public DocumentsUploadMultipartAbortRequestHandler() {}

  @Override
  public String getRequestUrl() {
    return "/documents/{documentId}/upload/multipart/{uploadId}";
  }

  @Override
  public Optional<Boolean> isAuthorized(final AwsServiceCache awsservice, final String method,
      final ApiGatewayRequestEvent event, final ApiAuthorization authorization) {
    String siteId = authorization.getSiteId();
    boolean access = authorization.getPermissions(siteId).contains(ApiPermission.WRITE);
    return Optional.of(access);
  }

  @Override
  public ApiRequestHandlerResponse delete(final ApiGatewayRequestEvent event,
      final ApiAuthorization authorization, final AwsServiceCache awsservice) throws Exception {

    String siteId = authorization.getSiteId();
    String documentId = event.getPathParameters().get("documentId");
    String uploadId = event.getPathParameters().get("uploadId");

    String s3Bucket = awsservice.environment("DOCUMENTS_S3_BUCKET");
    String key = !isDefaultSiteId(siteId) ? siteId + "/" + documentId : documentId;

    S3MultipartService multipartService = awsservice.getExtension(S3MultipartService.class);
    multipartService.abortMultipartUpload(s3Bucket, key, uploadId);

    return ApiRequestHandlerResponse.builder().ok()
        .body("documentId", documentId)
        .body("status", "aborted")
        .build();
  }
}
