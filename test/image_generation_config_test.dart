import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';

void main() {
  group('ImageGenerationConfig', () {
    test('round-trips public settings without any secret field', () {
      const config = ImageGenerationConfig(
        enabled: true,
        baseUrl: 'https://images.example/v1',
        model: 'artist-v2',
        protocol: ImageGenerationProtocol.asyncTask,
        width: 1536,
        height: 1024,
        aspectRatio: '3:2',
        outputFormat: 'webp',
        endpointPath: '/v1/jobs',
        statusEndpointTemplate: '/v1/jobs/{task_id}',
        pollIntervalSeconds: 3,
        maxPollAttempts: 120,
      );

      final encoded = config.toJson();
      expect(encoded.keys, isNot(contains('api_key')));
      expect(encoded.keys, isNot(contains('apiKey')));
      final decoded = ImageGenerationConfig.fromJson(encoded);
      expect(decoded.enabled, isTrue);
      expect(decoded.baseUrl, 'https://images.example/v1');
      expect(decoded.model, 'artist-v2');
      expect(decoded.protocol, ImageGenerationProtocol.asyncTask);
      expect(decoded.width, 1536);
      expect(decoded.height, 1024);
      expect(decoded.aspectRatio, '3:2');
      expect(decoded.outputFormat, 'webp');
      expect(decoded.endpointPath, '/v1/jobs');
      expect(decoded.statusEndpointTemplate, '/v1/jobs/{task_id}');
      expect(decoded.pollIntervalSeconds, 3);
      expect(decoded.maxPollAttempts, 120);
      expect(decoded.validationError, isNull);
    });

    test('parses stable and legacy protocol spellings', () {
      expect(
        ImageGenerationProtocolCodec.parse('openai_images'),
        ImageGenerationProtocol.openAiImages,
      );
      expect(
        ImageGenerationProtocolCodec.parse('OpenAI Responses'),
        ImageGenerationProtocol.openAiResponses,
      );
      expect(
        ImageGenerationProtocolCodec.parse('async-task'),
        ImageGenerationProtocol.asyncTask,
      );
      expect(
        ImageGenerationProtocolCodec.parse('comfy_ui'),
        ImageGenerationProtocol.comfyUi,
      );
      expect(
        ImageGenerationProtocolCodec.parse('future-provider'),
        ImageGenerationProtocol.auto,
      );
    });

    test('requires keys only for official keyed protocols', () {
      expect(ImageGenerationProtocol.openAiImages.requiresApiKey, isTrue);
      expect(ImageGenerationProtocol.openAiResponses.requiresApiKey, isTrue);
      expect(ImageGenerationProtocol.gemini.requiresApiKey, isTrue);
      expect(ImageGenerationProtocol.auto.requiresApiKey, isFalse);
      expect(ImageGenerationProtocol.syncJson.requiresApiKey, isFalse);
      expect(ImageGenerationProtocol.asyncTask.requiresApiKey, isFalse);
      expect(ImageGenerationProtocol.comfyUi.requiresApiKey, isFalse);
    });

    test('detects only endpoint formats with reliable URL evidence', () {
      expect(
        ImageGenerationConfig.detectProtocol(
          'https://api.openai.com/v1/images/generations',
        ),
        ImageGenerationProtocol.openAiImages,
      );
      expect(
        ImageGenerationConfig.detectProtocol(
          'https://relay.example/v1/responses',
        ),
        ImageGenerationProtocol.openAiResponses,
      );
      expect(
        ImageGenerationConfig.detectProtocol(
          'https://generativelanguage.googleapis.com/v1beta',
        ),
        ImageGenerationProtocol.gemini,
      );
      expect(
        ImageGenerationConfig.detectProtocol('http://127.0.0.1:8188'),
        ImageGenerationProtocol.comfyUi,
      );
      expect(
        ImageGenerationConfig.detectProtocol(
          'https://api.replicate.com/v1/predictions',
        ),
        ImageGenerationProtocol.asyncTask,
      );
      expect(
        ImageGenerationConfig.detectProtocol('https://unknown.example/make'),
        ImageGenerationProtocol.auto,
      );
      expect(
        ImageGenerationConfig.detectProtocol('https://unknown.example/v1'),
        ImageGenerationProtocol.auto,
      );
      expect(
        ImageGenerationConfig.detectProtocol('https://api.openai.com/v1'),
        ImageGenerationProtocol.openAiImages,
      );
    });

    test('auto also inspects a configured endpoint path', () {
      const config = ImageGenerationConfig(
        baseUrl: 'https://relay.example',
        endpointPath: '/v1/responses',
      );
      expect(config.resolvedProtocol, ImageGenerationProtocol.openAiResponses);
    });

    test('recognizes only verified Starlight API-base paths', () {
      for (final address in [
        'https://starlight.uno',
        'https://starlight.uno/',
        'https://starlight.uno/v1',
        'https://starlight.uno/v1/',
        'https://starlight.uno/v1?region=cn',
      ]) {
        expect(
          ImageGenerationConfig.detectProtocol(address),
          ImageGenerationProtocol.openAiImages,
          reason: address,
        );
      }
      for (final address in [
        'https://starlight.uno/v1/custom-generate',
        'https://api.starlight.uno/v1',
        'https://starlight.uno.example/v1',
        'https://another-provider.example/v1',
      ]) {
        expect(
          ImageGenerationConfig.detectProtocol(address),
          ImageGenerationProtocol.auto,
          reason: address,
        );
      }
    });

    test('custom endpoints and forced protocols override Starlight base', () {
      const config = ImageGenerationConfig(baseUrl: 'https://starlight.uno/v1');
      expect(config.resolvedProtocol, ImageGenerationProtocol.openAiImages);
      expect(
        config.copyWith(endpointPath: '/custom-generate').resolvedProtocol,
        ImageGenerationProtocol.auto,
      );
      expect(
        config
            .copyWith(endpointPath: 'https://images.example/custom-generate')
            .resolvedProtocol,
        ImageGenerationProtocol.auto,
      );
      expect(
        config.copyWith(endpointPath: '/v1/responses').resolvedProtocol,
        ImageGenerationProtocol.openAiResponses,
      );
      expect(
        config
            .copyWith(endpointPath: 'images/generations?quality=high')
            .resolvedProtocol,
        ImageGenerationProtocol.openAiImages,
      );
      expect(
        config
            .copyWith(protocol: ImageGenerationProtocol.syncJson)
            .resolvedProtocol,
        ImageGenerationProtocol.syncJson,
      );
    });

    test('requires HTTPS except for loopback development endpoints', () {
      expect(
        const ImageGenerationConfig(
          enabled: true,
          baseUrl: 'http://public.example/v1',
        ).validationError,
        'https_required',
      );
      expect(
        const ImageGenerationConfig(
          enabled: true,
          baseUrl: 'http://localhost:8188',
          protocol: ImageGenerationProtocol.comfyUi,
        ).validationError,
        isNull,
      );
    });

    test('rejects credentials embedded in any persisted endpoint URL', () {
      for (final config in [
        const ImageGenerationConfig(
          baseUrl: 'https://user:password@images.example/v1',
        ),
        const ImageGenerationConfig(
          baseUrl: 'https://images.example/v1?api_key=secret',
        ),
        const ImageGenerationConfig(
          baseUrl: 'https://images.example/v1',
          endpointPath: '/generate?KEY=secret',
        ),
        const ImageGenerationConfig(
          baseUrl: 'https://images.example/v1',
          statusEndpointTemplate: '/tasks/{task_id}?access-token=secret',
        ),
      ]) {
        expect(config.validationError, 'url_contains_credentials');
      }
      expect(
        const ImageGenerationConfig(
          baseUrl: 'https://images.example/v1?region=cn',
          endpointPath: '/generate?quality=high',
          statusEndpointTemplate: '/tasks/{task_id}?signature=temporary',
        ).validationError,
        isNull,
      );
    });

    test('default polling window is about fifteen minutes', () {
      const config = ImageGenerationConfig();
      expect(config.pollIntervalSeconds, 2);
      expect(config.maxPollAttempts, 450);
    });

    test('malformed imported values fall back to bounded defaults', () {
      final config = ImageGenerationConfig.fromJson({
        'enabled': true,
        'width': -1,
        'height': 99999,
        'poll_interval_seconds': 0,
        'max_poll_attempts': 9999,
        'output_format': 'JPEG',
      });
      expect(config.width, 1024);
      expect(config.height, 1024);
      expect(config.pollIntervalSeconds, 2);
      expect(config.maxPollAttempts, 450);
      expect(config.outputFormat, 'jpg');
    });
  });
}
