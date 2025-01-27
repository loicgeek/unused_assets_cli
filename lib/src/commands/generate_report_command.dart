import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:unused_assets_cli/src/helpers/utils_helper.dart';

/// {@template sample_command}
///
/// `unused_assets_cli sample`
/// A [Command] to exemplify a sub command
/// {@endtemplate}
class GenerateReportCommand extends Command<int> {
  /// {@macro sample_command}
  GenerateReportCommand({
    required Logger logger,
  }) : _logger = logger {
    // ignore: avoid_single_cascade_in_expression_statements
    argParser.addOption(
      'directory',
      abbr: 'd',
      help: 'Path to the flutter project',
    );
    // argParser
    //   ..addFlag(
    //     'directory',
    //     abbr: 'd',
    //     help: 'Path to the flutter project',
    //     negatable: false,
    //   );
    // ..addFlag(
    //   'output',
    //   abbr: 'o',
    //   help: 'Path to where the report will be saved',
    //   negatable: false,
    // );
  }

  @override
  String get description =>
      'The command to generate a report for unused assets.';

  @override
  String get name => 'report';

  final Logger _logger;

  @override
  Future<int> run() async {
    if (argResults?['directory'] == false) {
      _logger.err('The directory option is required.');
      return ExitCode.usage.code;
    }

    _logger.info("${argResults?.option('directory')}");
    final helper = UtilsHelper(
      logger: _logger,
      directory: argResults!.option('directory')!,
    );
    await helper.runUnusedAssets();
    return ExitCode.success.code;
  }
}
