import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fraction/fraction.dart';
import 'package:insta_assets_crop/insta_assets_crop.dart';
import 'package:insta_assets_picker/insta_assets_picker.dart';

/// Uses [InstaAssetsCropSingleton] to keep crop parameters in memory until the picker is disposed
/// Similar to [Singleton] class from `wechat_assets_picker` package
/// used only when [keepScrollOffset] is set to `true`
class InstaAssetsCropSingleton {
  const InstaAssetsCropSingleton._();

  static final Map<String, InstaAssetsCropData> cropParameters = {};
}

class InstaAssetsExportData {
  const InstaAssetsExportData({
    required this.croppedFile,
    required this.selectedData,
  });

  /// The cropped file, can be null if the asset is not an image or if the
  /// exportation was skipped ([skipCropOnComplete]=true)
  final File? croppedFile;

  /// The selected data, contains the asset and it's crop values
  final InstaAssetsCropData selectedData;
}

/// Contains all the parameters of the exportation
class InstaAssetsExportDetails {
  /// The export result, containing the selected assets, crop parameters
  /// and possible crop file.
  final List<InstaAssetsExportData> data;

  /// The selected thumbnails, can be provided to the picker to preselect those assets
  final List<AssetEntity> selectedAssets;

  /// The selected [aspectRatio]
  final double aspectRatio;

  /// The [progress] param represents progress indicator between `0.0` and `1.0`.
  final double progress;

  const InstaAssetsExportDetails({
    required this.data,
    required this.selectedAssets,
    required this.aspectRatio,
    required this.progress,
  });
}

/// The crop parameters state, can be used at exportation or to load the crop view
class InstaAssetsCropData {
  final AssetEntity asset;
  final CropInternal? cropParam;

  // export crop params
  final double scale;
  final Rect? area;

  /// Returns crop filter for ffmpeg in "out_w:out_h:x:y" format
  String? get ffmpegCrop {
    final area = this.area;
    if (area == null) return null;

    final w = area.width * asset.orientatedWidth;
    final h = area.height * asset.orientatedHeight;
    final x = area.left * asset.orientatedWidth;
    final y = area.top * asset.orientatedHeight;

    return '$w:$h:$x:$y';
  }

  /// Returns scale filter for ffmpeg in "iw*[scale]:ih*[scale]" format
  String? get ffmpegScale {
    final scale = cropParam?.scale;
    if (scale == null) return null;

    return 'iw*$scale:ih*$scale';
  }

  const InstaAssetsCropData({
    required this.asset,
    required this.cropParam,
    this.scale = 1.0,
    this.area,
  });

  static InstaAssetsCropData fromState({
    required AssetEntity asset,
    required CropState? cropState,
  }) {
    return InstaAssetsCropData(
      asset: asset,
      cropParam: cropState?.internalParameters,
      scale: cropState?.scale ?? 1.0,
      area: cropState?.area,
    );
  }
}

/// The controller that handles the exportation and save the state of the selected assets crop parameters
class InstaAssetsCropController {
  InstaAssetsCropController(this.keepMemory, this.cropDelegate) : cropRatioIndex = ValueNotifier<int>(0);

  /// The index of the selected aspectRatio among the possibilities
  final ValueNotifier<int> cropRatioIndex;

  /// Whether the asset in the crop view is loaded
  final ValueNotifier<bool> isCropViewReady = ValueNotifier<bool>(false);

  /// The asset [AssetEntity] currently displayed in the crop view
  final ValueNotifier<AssetEntity?> previewAsset = ValueNotifier<AssetEntity?>(null);

  /// Options related to crop
  final InstaAssetCropDelegate cropDelegate;

  /// List of all the crop parameters set by the user
  Map<String, InstaAssetsCropData> _cropParameters = {};

  /// Whether if [_cropParameters] should be saved in the cache to use when the picker
  /// is open with [InstaAssetPicker.restorableAssetsPicker]
  final bool keepMemory;

  dispose() {
    isCropViewReady.dispose();
    cropRatioIndex.dispose();
    previewAsset.dispose();
  }

  double get aspectRatio {
    assert(cropDelegate.cropRatios.isNotEmpty, 'The list of supported crop ratios cannot be empty.');
    return cropDelegate.cropRatios[cropRatioIndex.value];
  }

  String get aspectRatioString {
    final r = aspectRatio;
    if (r == 1) return '1:1';
    return Fraction.fromDouble(r).reduce().toString().replaceFirst('/', ':');
  }

  /// Set the next available index as the selected crop ratio
  void nextCropRatio() {
    if (cropRatioIndex.value < cropDelegate.cropRatios.length - 1) {
      cropRatioIndex.value = cropRatioIndex.value + 1;
    } else {
      cropRatioIndex.value = 0;
    }
  }

  /// Use [_cropParameters] when [keepMemory] is `false`, otherwise use [InstaAssetsCropSingleton.cropParameters]
  Map<String, InstaAssetsCropData> get cropParameters => keepMemory ? InstaAssetsCropSingleton.cropParameters : _cropParameters;

  /// Save the list of crop parameters
  /// if [keepMemory] save list memory or simply in the controller
  void updateStoreCropParam(Map<String, InstaAssetsCropData> map) {
    if (keepMemory) {
      InstaAssetsCropSingleton.cropParameters
        ..clear()
        ..addAll(map);
    } else {
      _cropParameters = map;
    }
  }

  /// Clear all the saved crop parameters
  void clear() {
    updateStoreCropParam({});
    previewAsset.value = null;
  }

  /// When the preview asset is changed, save the crop parameters of the previous asset
  void onChange(
    AssetEntity? saveAsset,
    CropState? saveCropState,
    List<AssetEntity> selectedAssets,
  ) {
    final Map<String, InstaAssetsCropData> newMap = {};

    for (final asset in selectedAssets) {
      if (asset == saveAsset && saveAsset != null) {
        newMap[asset.id] = InstaAssetsCropData.fromState(
          asset: asset,
          cropState: saveCropState,
        );
      } else {
        final saved = get(asset);
        newMap[asset.id] = saved ?? InstaAssetsCropData.fromState(asset: asset, cropState: null);
      }
    }
    updateStoreCropParam(newMap);
  }

  /// Returns the crop parametes [InstaAssetsCropData] of the given asset
  InstaAssetsCropData? get(AssetEntity asset) {
    return cropParameters[asset.id];
  }

  /// Apply all the crop parameters to the list of [selectedAssets]
  /// and returns the exportation as a [Stream]
  Stream<InstaAssetsExportDetails> exportCropFiles(
    List<AssetEntity> selectedAssets, {
    bool skipCrop = false,
  }) async* {
    final List<InstaAssetsExportData> data = [];

    /// Returns the [InstaAssetsExportDetails] with given progress value [p]
    InstaAssetsExportDetails makeDetail(double p) => InstaAssetsExportDetails(
          data: data,
          selectedAssets: selectedAssets,
          aspectRatio: aspectRatio,
          progress: p,
        );

    // start progress
    yield makeDetail(0);
    final Map<String, InstaAssetsCropData> map = cropParameters;
    final step = 1 / selectedAssets.length;

    for (int i = 0; i < selectedAssets.length; i++) {
      final asset = selectedAssets[i];
      final cropData = map[asset.id] ?? InstaAssetsCropData.fromState(asset: asset, cropState: null);

      if (skipCrop || asset.type != AssetType.image) {
        data.add(InstaAssetsExportData(croppedFile: null, selectedData: cropData));
      } else {
        final file = await asset.originFile;

        final scale = cropData.scale;
        final area = cropData.area;

        if (file == null) {
          throw 'error file is null';
        }

        // makes the sample file to not be too small
        final sampledFile = await InstaAssetsCrop.sampleImage(
          file: file,
          preferredSize: (cropDelegate.preferredSize / scale).round(),
        );

        if (area == null) {
          data.add(InstaAssetsExportData(croppedFile: sampledFile, selectedData: cropData));
        } else {
          // crop the file with the area selected
          final croppedFile = await InstaAssetsCrop.cropImage(file: sampledFile, area: area);
          // delete the not needed sample file
          sampledFile.delete();

          data.add(InstaAssetsExportData(croppedFile: croppedFile, selectedData: cropData));
        }
      }

      // increase progress
      final progress = (i + 1) * step;
      if (progress < 1) {
        yield makeDetail(progress);
      }
    }
    // complete progress
    yield makeDetail(1);
  }
}
