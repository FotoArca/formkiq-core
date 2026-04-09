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
import com.formkiq.aws.s3.S3PresignerService;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEvent;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEventUtil;
import com.formkiq.aws.services.lambda.ApiGatewayRequestHandler;
import com.formkiq.aws.dynamodb.ApiPermission;
import com.formkiq.aws.services.lambda.ApiRequestHandlerResponse;
import com.formkiq.aws.services.lambda.exceptions.BadException;
import com.formkiq.module.lambdaservices.AwsServiceCache;

import java.net.URL;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static com.formkiq.aws.dynamodb.SiteIdKeyGenerator.isDefaultSiteId;

/**
 * {@link ApiGatewayRequestHandler} for GET
 * "/documents/{documentId}/upload/multipart/{uploadId}/parts".
 *
 * Returns presigned URLs for uploading individual parts of a multipart upload.
 */
public class DocumentsUploadMultipartPartRequestHandler
    implements ApiGatewayRequestHandler, ApiGatewayRequestEventUtil {

  /** Default presigned URL duration in hours. */
  private static final int DEFAULT_DURATION_HOURS = 1;
  /** Maximum number of part URLs per request. */
  private static final int MAX_PARTS_PER_REQUEST = 10;
  /** Maximum S3 part number. */
  private static final int MAX_PART_NUMBER = 10000;

  /** constructor. */
  public DocumentsUploadMultipartPartRequestHandler() {}

  @Override
  public String getRequestUrl() {
    return "/documents/{documentId}/upload/multipart/{uploadId}/parts";
  }

  @Override
  public Optional<Boolean> isAuthorized(final AwsServiceCache awsservice, final String method,
      final ApiGatewayRequestEvent event, final ApiAuthorization authorization) {
    String siteId = authorization.getSiteId();
    boolean access = authorization.getPermissions(siteId).contains(ApiPermission.WRITE);
    return Optional.of(access);
  }

  @Override
  public ApiRequestHandlerResponse get(final ApiGatewayRequestEvent event,
      final ApiAuthorization authorization, final AwsServiceCache awsservice) throws Exception {

    String siteId = authorization.getSiteId();
    String documentId = event.getPathParameters().get("documentId");
    String uploadId = event.getPathParameters().get("uploadId");

    Map<String, String> query = event.getQueryStringParameters();
    String partNumbersParam = query != null ? query.get("partNumbers") : null;

    if (partNumbersParam == null || partNumbersParam.isEmpty()) {
      throw new BadException("'partNumbers' query parameter is required (e.g. partNumbers=1,2,3)");
    }

    String[] partNumberStrs = partNumbersParam.split(",");
    if (partNumberStrs.length > MAX_PARTS_PER_REQUEST) {
      throw new BadException(
          "Maximum " + MAX_PARTS_PER_REQUEST + " part numbers per request");
    }

    List<Integer> partNumbers = new ArrayList<>();
    for (String pn : partNumberStrs) {
      int partNumber = Integer.parseInt(pn.trim());
      if (partNumber < 1 || partNumber > MAX_PART_NUMBER) {
        throw new BadException("Part number must be between 1 and " + MAX_PART_NUMBER);
      }
      partNumbers.add(partNumber);
    }

    String s3Bucket = awsservice.environment("DOCUMENTS_S3_BUCKET");
    String key = !isDefaultSiteId(siteId) ? siteId + "/" + documentId : documentId;
    Duration duration = Duration.ofHours(DEFAULT_DURATION_HOURS);

    S3PresignerService presignerService = awsservice.getExtension(S3PresignerService.class);

    List<Map<String, Object>> parts = new ArrayList<>();
    for (int partNumber : partNumbers) {
      URL url = presignerService.presignUploadPartUrl(s3Bucket, key, duration, uploadId,
          partNumber, Optional.empty());

      Map<String, Object> partMap = new HashMap<>();
      partMap.put("partNumber", partNumber);
      partMap.put("url", url.toString());
      parts.add(partMap);
    }

    return ApiRequestHandlerResponse.builder().ok()
        .body("parts", parts)
        .build();
  }
}
