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

import com.formkiq.aws.dynamodb.ID;
import com.formkiq.aws.dynamodb.model.DocumentItem;
import com.formkiq.aws.dynamodb.objects.Strings;
import com.formkiq.aws.dynamodb.ApiAuthorization;
import com.formkiq.aws.s3.S3MultipartService;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEvent;
import com.formkiq.aws.services.lambda.ApiGatewayRequestEventUtil;
import com.formkiq.aws.services.lambda.ApiGatewayRequestHandler;
import com.formkiq.aws.dynamodb.ApiPermission;
import com.formkiq.aws.services.lambda.ApiRequestHandlerResponse;
import com.formkiq.aws.services.lambda.JsonToObject;
import com.formkiq.aws.services.lambda.exceptions.BadException;
import com.formkiq.module.lambdaservices.AwsServiceCache;
import com.formkiq.stacks.dynamodb.DocumentItemDynamoDb;
import com.formkiq.stacks.dynamodb.DocumentService;
import com.formkiq.stacks.dynamodb.SaveDocumentOptions;
import com.formkiq.stacks.dynamodb.attributes.AttributeValidationAccess;
import com.formkiq.stacks.dynamodb.config.ConfigService;
import com.formkiq.stacks.dynamodb.config.SiteConfiguration;

import java.util.ArrayList;
import java.util.Map;
import java.util.Optional;

import static com.formkiq.aws.dynamodb.SiteIdKeyGenerator.isDefaultSiteId;
import static com.formkiq.aws.dynamodb.objects.Strings.isEmpty;

/**
 * {@link ApiGatewayRequestHandler} for POST "/documents/upload/multipart".
 *
 * Initiates an S3 multipart upload and creates the document record.
 * Returns the documentId, uploadId, and S3 key for subsequent part uploads.
 */
public class DocumentsUploadMultipartRequestHandler
    implements ApiGatewayRequestHandler, ApiGatewayRequestEventUtil {

  /** {@link DocumentsRestrictionsMaxContentLength}. */
  private final DocumentsRestrictionsMaxContentLength restrictionMaxContentLength =
      new DocumentsRestrictionsMaxContentLength();

  /** constructor. */
  public DocumentsUploadMultipartRequestHandler() {}

  @Override
  public String getRequestUrl() {
    return "/documents/upload/multipart";
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

    AddDocumentRequest request = JsonToObject.fromJson(awsservice, event, AddDocumentRequest.class);

    String siteId = authorization.getSiteId();

    if (isEmpty(request.getDocumentId())) {
      request.setDocumentId(ID.uuid());
    }

    String documentId = request.getDocumentId();

    Map<String, String> query = event.getQueryStringParameters();
    Long contentLength = query != null && query.containsKey("contentLength")
        ? Long.valueOf(query.get("contentLength"))
        : null;

    if (contentLength == null) {
      throw new BadException("'contentLength' is required for multipart uploads");
    }

    validateContentLength(awsservice, siteId, contentLength);

    String s3Bucket = awsservice.environment("DOCUMENTS_S3_BUCKET");
    String key = !isDefaultSiteId(siteId) ? siteId + "/" + documentId : documentId;
    String contentType = request.getContentType();

    S3MultipartService multipartService = awsservice.getExtension(S3MultipartService.class);
    String uploadId = multipartService.createMultipartUpload(s3Bucket, key, contentType);

    DocumentItem item =
        new AddDocumentRequestToDocumentItem(null, authorization.getUsername(), null)
            .apply(request);

    boolean isAdmin = authorization.isAdminOrGovern(siteId);
    AttributeValidationAccess validationAccess =
        isAdmin ? AttributeValidationAccess.ADMIN_CREATE : AttributeValidationAccess.CREATE;
    SaveDocumentOptions options =
        new SaveDocumentOptions().saveDocumentDate(true).validationAccess(validationAccess);

    DocumentService service = awsservice.getExtension(DocumentService.class);
    service.saveDocument(siteId, item, new ArrayList<>(), null, options);

    return ApiRequestHandlerResponse.builder().created()
        .body("documentId", documentId)
        .body("uploadId", uploadId)
        .body("key", key)
        .body("bucket", s3Bucket)
        .build();
  }

  private void validateContentLength(final AwsServiceCache awsservice, final String siteId,
      final Long contentLength) throws BadException {

    ConfigService configService = awsservice.getExtension(ConfigService.class);
    SiteConfiguration siteConfiguration = configService.get(siteId);

    if (!Strings.isEmpty(siteConfiguration.maxContentLengthBytes())) {
      DocumentItem item = new DocumentItemDynamoDb();
      item.setContentLength(contentLength);

      if (this.restrictionMaxContentLength.isViolated(awsservice, siteConfiguration, siteId,
          item)) {
        throw new BadException("'contentLength' cannot exceed "
            + siteConfiguration.maxContentLengthBytes() + " bytes");
      }
    }
  }
}
