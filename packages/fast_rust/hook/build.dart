// Build hook: compiles the Rust crate in `rust/` with cargo for the exact
// target the Dart/Flutter SDK asks for, and registers the resulting dynamic
// library as a code asset. Runs automatically on `dart run`, `dart test`,
// `flutter run`, `flutter build` and `flutter test`.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _crateName = 'fast_rust';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final triple = _rustTriple(code);
    final crateDir = input.packageRoot.resolve('rust/');
    final targetDir = input.outputDirectoryShared.resolve('cargo/');

    final env = <String, String>{
      'CARGO_TARGET_DIR': targetDir.toFilePath(),
      ..._toolchainEnv(code, triple),
    };

    final cargo = _findCargo();
    final result = await Process.run(
      cargo,
      [
        // `cargo rustc` appends flags after `--` even when the environment
        // sets RUSTFLAGS (which would silently replace target rustflags).
        'rustc', '--release', '--lib', '--crate-type', 'cdylib',
        '--target', triple,
        if (code.targetOS == OS.android) ...[
          '--',
          // Android 15+ devices may use 16 KB pages.
          '-C', 'link-arg=-Wl,-z,max-page-size=16384',
        ],
      ],
      workingDirectory: crateDir.toFilePath(),
      environment: env,
    );
    if (result.exitCode != 0) {
      throw Exception(
        'cargo rustc --target $triple failed (exit ${result.exitCode}).\n'
        '${result.stdout}\n${result.stderr}\n'
        'If the target is missing, run: rustup target add $triple',
      );
    }

    final libName = code.targetOS.dylibFileName(_crateName);
    final built = File.fromUri(targetDir.resolve('$triple/release/$libName'));
    final bundled = input.outputDirectory.resolve(libName);
    await built.copy(bundled.toFilePath());

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: bundled,
      ),
    );

    // Re-run when any Rust source changes. Directory dependencies only hash
    // child names, so list every file explicitly.
    for (final name in ['Cargo.toml', 'Cargo.lock']) {
      output.dependencies.add(crateDir.resolve(name));
    }
    await for (final entity in Directory.fromUri(
      crateDir.resolve('src/'),
    ).list(recursive: true)) {
      if (entity is File) output.dependencies.add(entity.uri);
    }
  });
}

String _rustTriple(CodeConfig code) {
  final os = code.targetOS;
  final arch = code.targetArchitecture;
  String unsupported() =>
      throw UnsupportedError('fast_rust: unsupported target $os/$arch');
  return switch (os) {
    OS.android => switch (arch) {
      Architecture.arm64 => 'aarch64-linux-android',
      Architecture.arm => 'armv7-linux-androideabi',
      Architecture.x64 => 'x86_64-linux-android',
      Architecture.ia32 => 'i686-linux-android',
      _ => unsupported(),
    },
    OS.iOS => switch ((arch, code.iOS.targetSdk)) {
      (Architecture.arm64, IOSSdk.iPhoneOS) => 'aarch64-apple-ios',
      (Architecture.arm64, IOSSdk.iPhoneSimulator) => 'aarch64-apple-ios-sim',
      (Architecture.x64, IOSSdk.iPhoneSimulator) => 'x86_64-apple-ios',
      _ => unsupported(),
    },
    OS.macOS => switch (arch) {
      Architecture.arm64 => 'aarch64-apple-darwin',
      Architecture.x64 => 'x86_64-apple-darwin',
      _ => unsupported(),
    },
    OS.linux => switch (arch) {
      Architecture.arm64 => 'aarch64-unknown-linux-gnu',
      Architecture.x64 => 'x86_64-unknown-linux-gnu',
      _ => unsupported(),
    },
    OS.windows => switch (arch) {
      Architecture.arm64 => 'aarch64-pc-windows-msvc',
      Architecture.x64 => 'x86_64-pc-windows-msvc',
      _ => unsupported(),
    },
    _ => unsupported(),
  };
}

/// Linker and deployment-target settings cargo cannot infer on its own.
Map<String, String> _toolchainEnv(CodeConfig code, String triple) {
  final envTriple = triple.toUpperCase().replaceAll('-', '_');
  switch (code.targetOS) {
    case OS.android:
      // The SDK hands us the NDK clang; the per-API wrapper scripts live
      // next to it, e.g. aarch64-linux-android24-clang.
      final clang = code.cCompiler?.compiler;
      if (clang == null) {
        throw StateError('fast_rust: Android build needs the NDK C compiler.');
      }
      final api = code.android.targetNdkApi;
      final clangTarget = triple.replaceFirst('armv7-', 'armv7a-');
      final binDir = File.fromUri(clang).parent.path;
      final ext = Platform.isWindows ? '.cmd' : '';
      return {
        'CARGO_TARGET_${envTriple}_LINKER':
            '$binDir${Platform.pathSeparator}$clangTarget$api-clang$ext',
      };
    case OS.macOS:
      return {'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}'};
    case OS.iOS:
      return {'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}'};
    default:
      return const {};
  }
}

/// cargo from PATH, falling back to the default rustup install location
/// (GUI-launched IDEs often miss ~/.cargo/bin on PATH).
String _findCargo() {
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null) {
    final candidate = File(
      '$home${Platform.pathSeparator}.cargo${Platform.pathSeparator}'
      'bin${Platform.pathSeparator}$exe',
    );
    if (candidate.existsSync()) return candidate.path;
  }
  return exe;
}
