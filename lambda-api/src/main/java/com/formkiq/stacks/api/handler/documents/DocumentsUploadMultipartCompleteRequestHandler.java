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
import com.formkiq.aws.s3.S3MultipartService;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEvent;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEventUtil;
import com.formkiq.aws.services.lambda.ApiGatewayRequestHandler;
import com.formkiq.aws.dynamodb.ApiPermission;
import com.formkiq.aws.services.lambda.ApiRequestHandlerResponse;
import com.formkiq.aws.services.lambda.exceptions.BadException;
import com.formkiq.module.lambdaservices.AwsServiceCache;
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import software.amazon.awssdk.services.s3.model.CompletedPart;

import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static com.formkiq.aws.dynamodb.SiteIdKeyGenerator.isDefaultSiteId;

/**
 * {@link ApiGatewayRequestHandler} for
 * POST "/documents/{documentId}/upload/multipart/{uploadId}/complete".
 *
 * Completes a multipart upload. Aborting an upload is handled by
 * {@link DocumentsUploadMultipartAbortRequestHandler}.
 */
public class DocumentsUploadMultipartCompleteRequestHandler
    implements ApiGatewayRequestHandler, ApiGatewayRequestEventUtil {

  /** constructor. */
  public DocumentsUploadMultipartCompleteRequestHandler() {}

  @Override
  public String getRequestUrl() {
    return "/documents/{documentId}/upload/multipart/{uploadId}/complete";
  }

  @Override
  public Optional<Boolean> isAuthorized(final AwsServiceCache awsservice, final String method,
      final ApiGatewayRequestEvent event, final ApiAuthorization authorization) {
    String siteId = authorization.getSiteId();
    boolean access = authorization.getPermissions(siteId).contains(ApiPermission.WRITE);
    return Optional.of(access);
  }

  @Override
  public ApiRequestHandlerResponse post(final ApiGatewayRequestEvent event,
      final ApiAuthorization authorization, final AwsServiceCache awsservice) throws Exception {

    String siteId = authorization.getSiteId();
    String documentId = event.getPathParameters().get("documentId");
    String uploadId = event.getPathParameters().get("uploadId");

    String body = event.getBody();
    if (body == null || body.isEmpty()) {
      throw new BadException("Request body is required with 'parts' array");
    }

    Gson gson = awsservice.getExtension(Gson.class);
    Type mapType = new TypeToken<Map<String, Object>>() {}.getType();
    Map<String, Object> bodyMap = gson.fromJson(body, mapType);

    @SuppressWarnings("unchecked")
    List<Map<String, Object>> partsData = (List<Map<String, Object>>) bodyMap.get("parts");
    if (partsData == null || partsData.isEmpty()) {
      throw new BadException("'parts' array is required and must not be empty");
    }

    List<CompletedPart> completedParts = new ArrayList<>();
    for (Map<String, Object> partData : partsData) {
      Number partNumberNum = (Number) partData.get("partNumber");
      String eTag = (String) partData.get("eTag");

      if (partNumberNum == null || eTag == null) {
        throw new BadException("Each part requires 'partNumber' and 'eTag'");
      }

      completedParts.add(CompletedPart.builder()
          .partNumber(partNumberNum.intValue())
          .eTag(eTag)
          .build());
    }

    String s3Bucket = awsservice.environment("DOCUMENTS_S3_BUCKET");
    String key = !isDefaultSiteId(siteId) ? siteId + "/" + documentId : documentId;

    S3MultipartService multipartService = awsservice.getExtension(S3MultipartService.class);
    multipartService.completeMultipartUpload(s3Bucket, key, uploadId, completedParts);

    return ApiRequestHandlerResponse.builder().ok()
        .body("documentId", documentId)
        .body("status", "complete")
        .build();
  }
}
