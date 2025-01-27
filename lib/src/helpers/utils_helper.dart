import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';

class UtilsHelper {
  UtilsHelper({
    required Logger logger,
    required String directory,
  })  : _logger = logger,
        _directory = directory;
  late final Logger _logger;
  late final String _directory;

  Future<void> runUnusedAssets() async {
    final assetsPath = '$_directory/assets';
    final sourcePath = '$_directory/lib';
    final reportFile = '$_directory/unused_assets.json';
    final pubspecFile = '$_directory/pubspec.yaml';

    // Check if pubspec.yaml exists
    if (!File(pubspecFile).existsSync()) {
      _logger.info(
        'Error: pubspec.yaml not found. Are you in a Flutter project directory?',
      );
      return;
    }

    // Get declared assets from pubspec.yaml
    final declaredAssets = await getDeclaredAssets(pubspecFile);
    if (declaredAssets.isEmpty) {
      _logger.info('No assets declared in pubspec.yaml');
      return;
    }

    // Get actual assets from the assets directory
    final assetFiles = await listAssetsInFolder(assetsPath, assetsPath);
    if (assetFiles.isEmpty) {
      _logger.info('No assets found in the "$assetsPath" folder.');
      return;
    }

    // Find referenced assets in code
    final referencedAssets = await findAssetReferences(sourcePath);

    // Check for assets that exist but aren't declared in pubspec.yaml
    final undeclaredAssets = assetFiles
        .where((asset) => !isAssetDeclared(asset, declaredAssets))
        .toList();

    // Check for declared assets that don't exist
    final missingAssets = declaredAssets
        .where(
          (declared) => !assetFiles
              .any((file) => file.startsWith(declared.replaceAll('/*', ''))),
        )
        .toList();

    // Find unused assets and calculate their sizes
    final unusedAssetsInfo = await getUnusedAssetsInfo(
      assetFiles,
      referencedAssets,
      declaredAssets,
      _directory,
    );

    final report = {
      'total_assets': assetFiles.length,
      'declared_assets': declaredAssets.length,
      'referenced_assets': referencedAssets.length,
      'unused_assets': unusedAssetsInfo['assets'],
      'unused_assets_count': unusedAssetsInfo['count'],
      'unused_assets_total_size': unusedAssetsInfo['totalSize'],
      'undeclared_assets': undeclaredAssets,
      'missing_declared_assets': missingAssets,
    };

    // Save the report
    final file = File(reportFile);
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));

    // Print summary
    printReport(report);
  }

  /// Get assets declared in pubspec.yaml using simple string parsing
  Future<List<String>> getDeclaredAssets(String pubspecPath) async {
    final file = File(pubspecPath);
    final content = await file.readAsString();
    final assets = <String>[];
    var inFlutterSection = false;
    var inAssetsSection = false;

    for (final line in content.split('\n')) {
      final trimmed = line.trim();

      if (trimmed == 'flutter:') {
        inFlutterSection = true;
        continue;
      }

      if (inFlutterSection && trimmed == 'assets:') {
        inAssetsSection = true;
        continue;
      }

      if (inAssetsSection) {
        if (trimmed.startsWith('-')) {
          // Extract asset path, removing the leading '- ' and any quotes
          var assetPath = trimmed
              .substring(1)
              .trim()
              .replaceAll(RegExp(r'''^["\']|["\']$'''), '');
          if (assetPath.isNotEmpty) {
            // Ensure the path starts with 'assets/'
            if (!assetPath.startsWith('assets/')) {
              assetPath = 'assets/$assetPath';
            }
            assets.add(assetPath);
          }
        } else if (!trimmed.startsWith(' ') && trimmed.isNotEmpty) {
          // We've exited the assets section
          break;
        }
      }
    }

    return assets;
  }

  /// Check if an asset is covered by pubspec declarations
  bool isAssetDeclared(String assetPath, List<String> declarations) {
    return declarations.any((declaration) {
      // If the declaration ends with /*, it's a folder declaration
      if (declaration.endsWith('/*')) {
        final folderPath = declaration.substring(0, declaration.length - 2);
        return assetPath.startsWith(folderPath);
      }
      // If the declaration is a folder without *, still treat it as a folder declaration
      if (!declaration.contains('.')) {
        return assetPath.startsWith(declaration);
      }
      return assetPath == declaration;
    });
  }

  /// List all files in the assets folder recursively
  Future<List<String>> listAssetsInFolder(String path, String basePath) async {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      _logger.info('Assets folder "$path" not found.');
      return [];
    }

    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File)
        .map((entity) {
      final relativePath =
          entity.path.replaceAll('\\', '/').replaceFirst('$basePath/', '');
      // Ensure the path starts with 'assets/'

      return relativePath.startsWith('assets/')
          ? relativePath
          : 'assets/$relativePath';
    }).toList();

    return files;
  }

  /// Find asset references in Dart files
  Future<Set<String>> findAssetReferences(String sourcePath) async {
    final directory = Directory(sourcePath);
    if (!directory.existsSync()) {
      _logger.info('Source folder "$sourcePath" not found.');
      return {};
    }

    final references = <String>{};

    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        final content = await entity.readAsString();

        // Match common Flutter asset patterns
        final patterns = [
          // Direct string references
          (
            r'''["'](assets\/.*?\.(png|jpg|jpeg|svg|json|mp3|mp4|gif|webp))["']''',
            1
          ),
          // AssetImage references
          (r'''AssetImage\(["'](.+?)["']\)''', 1),
          // Image.asset references
          (r'''Image\.asset\(["'](.+?)["']\)''', 1),
          // Variable assignments
          (
            r'''(\w+)\s*=\s*["'](.+?\.(?:png|jpg|jpeg|svg|json|mp3|mp4|gif|webp))["']''',
            2
          ),
        ];

        for (final (pattern, groupIndex) in patterns) {
          final matches = RegExp(pattern).allMatches(content);
          for (final match in matches) {
            if (match.groupCount >= groupIndex) {
              var assetPath = match.group(groupIndex)!;
              // Ensure the path starts with 'assets/'
              if (!assetPath.startsWith('assets/')) {
                assetPath = 'assets/$assetPath';
              }
              references.add(assetPath);
            }
          }
        }
      }
    }

    return references;
  }

  /// Find unused assets
  List<String> listUnusedAssets(
    List<String> assets,
    Set<String> references,
    List<String> declarations,
  ) {
    return assets
        .where(
          (asset) =>
              isAssetDeclared(asset, declarations) && // Asset is declared
              !references.contains(asset),
        ) // But not referenced
        .toList();
  }

// Get information about unused assets including count and total size
  Future<Map<String, dynamic>> getUnusedAssetsInfo(
    List<String> assets,
    Set<String> references,
    List<String> declarations,
    String baseDirectory,
  ) async {
    final unusedAssets = assets
        .where(
          (asset) =>
              isAssetDeclared(asset, declarations) && // Asset is declared
              !references.contains(asset),
        ) // But not referenced
        .toList();

    var totalSize = 0;
    final unusedAssetsWithSize = <Map<String, dynamic>>[];

    for (final asset in unusedAssets) {
      final file = File('$baseDirectory/$asset');
      if (file.existsSync()) {
        final size = await file.length();
        totalSize += size;
        unusedAssetsWithSize.add({
          'path': asset,
          'size': size,
          'formattedSize': _formatFileSize(size),
        });
      }
    }
    unusedAssetsWithSize.sort(
      (a, b) => (b['size'] as int).compareTo(a['size'] as int),
    );

    return {
      'assets': unusedAssetsWithSize,
      'count': unusedAssets.length,
      'totalSize': totalSize,
    };
  }

  /// Format file size into human-readable format
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Print a human-readable report
  void printReport(Map<String, dynamic> report) {
    _logger.info('\nAsset Analysis Report:');
    _logger.info('--------------------');
    _logger.info('Total assets found: ${report['total_assets']}');
    _logger.info('Declared assets: ${report['declared_assets']}');
    _logger.info('Referenced assets: ${report['referenced_assets']}');

    final unusedAssetsInfo = report['unused_assets'] as List;
    final totalUnusedSize = report['unused_assets_total_size'] as int;

    _logger.info(
      '\nUnused assets: ${report['unused_assets_count']} (Total size: ${_formatFileSize(totalUnusedSize)})',
    );
    if (unusedAssetsInfo.isNotEmpty) {
      _logger.info('Unused assets list:');
      for (final asset in unusedAssetsInfo) {
        _logger.info('  - ${asset['path']} (${asset['formattedSize']})');
      }
    }

    if ((report['undeclared_assets'] as List).isNotEmpty) {
      _logger.info(
        '\nWarning: Found ${report['undeclared_assets'].length} undeclared assets:',
      );
      for (final asset in report['undeclared_assets'] as List) {
        _logger.info('  - $asset');
      }
    }

    if ((report['missing_declared_assets'] as List).isNotEmpty) {
      _logger.info(
        '\nWarning: Found ${report['missing_declared_assets'].length} missing declared assets:',
      );
      for (final asset in report['missing_declared_assets'] as List) {
        _logger.info('  - $asset');
      }
    }

    _logger
        .info('\nDetailed report saved to "${_directory}/unused_assets.json"');
  }
}
