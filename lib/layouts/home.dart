import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dji_mapper/components/app_bar.dart';
import 'package:dji_mapper/core/drone_mapping_engine.dart';
import 'package:dji_mapper/layouts/aircraft.dart';
import 'package:dji_mapper/layouts/camera.dart';
import 'package:dji_mapper/layouts/export.dart';
import 'package:dji_mapper/layouts/info.dart';
import 'package:dji_mapper/presets/preset_manager.dart';
import 'package:dji_mapper/shared/value_listeneables.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../shared/aircraft_settings.dart';

class HomeLayout extends StatefulWidget {
  const HomeLayout({super.key});

  @override
  State<HomeLayout> createState() => _HomeLayoutState();
}

class _HomeLayoutState extends State<HomeLayout> with TickerProviderStateMixin {
  final MapController mapController = MapController();
  late final TabController _tabController;

  final List<Marker> _photoMarkers = [];

  final _debounce = const Duration(milliseconds: 800);
  Timer? _debounceTimer;
  List<MapSearchLocation> _searchLocations = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _getLocationAndMoveMap();

    final presets = PresetManager.getPresets();
    Provider.of<ValueListenables>(context, listen: false).selectedCameraPreset =
        presets[0];

    final listenables = Provider.of<ValueListenables>(context, listen: false);

    final settings = AircraftSettings.getAircraftSettings();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      listenables.altitude = settings.altitude;
      listenables.speed = settings.speed;
      listenables.forwardOverlap = settings.forwardOverlap;
      listenables.sideOverlap = settings.sideOverlap;
      listenables.rotation = settings.rotation;
      listenables.delayAtWaypoint = settings.delay;
      listenables.cameraAngle = settings.cameraAngle;
      listenables.onFinished = settings.finishAction;
      listenables.rcLostAction = settings.rcLostAction;
    });
  }

  Future<void> _search(String query) async {
    var response = await Dio().get(
      "https://nominatim.openstreetmap.org/search",
      queryParameters: {
        "q": query,
        "format": "jsonv2",
      },
    );

    List<MapSearchLocation> locations = [];
    for (var location in response.data) {
      locations.add(MapSearchLocation(
        name: location["display_name"],
        type: location["type"],
        location: LatLng(
            double.parse(location["lat"]), double.parse(location["lon"])),
      ));
    }

    setState(() {
      _searchLocations = locations;
    });
  }

  void _onSearchChanged(
      String query, Function(List<MapSearchLocation>) callback) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(_debounce, () async {
      await _search(query);

      callback(_searchLocations);
    });
  }

  void _getLocationAndMoveMap() async {
    if (await Geolocator.isLocationServiceEnabled() == false) return;
    if (await Geolocator.checkPermission() == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    final location = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low);
    mapController.move(LatLng(location.latitude, location.longitude), 14);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _buildMarkers(ValueListenables listenables) {
    var droneMapping = DroneMappingEngine(
      altitude: listenables.altitude.toDouble(),
      forwardOverlap: listenables.forwardOverlap / 100,
      sideOverlap: listenables.sideOverlap / 100,
      sensorWidth: listenables.sensorWidth,
      sensorHeight: listenables.sensorHeight,
      focalLength: listenables.focalLength,
      imageWidth: listenables.imageWidth,
      imageHeight: listenables.imageHeight,
      angle: listenables.rotation.toDouble(),
    );

    var waypoints = droneMapping.generateWaypoints(listenables.polygon);
    listenables.photoLocations = waypoints;
    if (waypoints.isEmpty) return;
    _photoMarkers.clear();
    for (var photoLocation in waypoints) {
      _photoMarkers.add(Marker(
          point: photoLocation,
          alignment: Alignment.center,
          rotate: false,
          child: Center(
            child: Icon(Icons.photo_camera,
                size: 25, color: Theme.of(context).colorScheme.tertiary),
          )));
    }
    listenables.flightLine = Polyline(
        points: waypoints,
        strokeWidth: 3,
        color: Theme.of(context).colorScheme.tertiary);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ValueListenables>(
      builder: (context, listenables, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (listenables.polygon.length > 2 && listenables.altitude >= 5) {
            _buildMarkers(listenables);
          } else {
            listenables.photoLocations.clear();
            listenables.flightLine = null;
          }
        });

        var children = [
          Flexible(
            flex: MediaQuery.of(context).size.width < 700 ? 1 : 2,
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                onTap: (tapPosition, point) => {
                  setState(() {
                    listenables.polygon.add(point);
                  }),
                },
              ),
              children: [
                TileLayer(
                  tileProvider: CancellableNetworkTileProvider(),
                  tileBuilder: Theme.of(context).brightness == Brightness.dark
                      ? (context, tileWidget, tile) =>
                          darkModeTileBuilder(context, tileWidget, tile)
                      : null,
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.yarosfpv.dji_mapper',
                ),
                PolygonLayer(polygons: [
                  Polygon(
                      points: listenables.polygon,
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.3),
                      isFilled: true,
                      borderColor: Theme.of(context).colorScheme.primary,
                      borderStrokeWidth: 3),
                ]),
                if (listenables.showCameras)
                  MarkerLayer(markers: _photoMarkers),
                PolylineLayer(polylines: [
                  listenables.flightLine ?? Polyline(points: [])
                ]),
                DragMarkers(markers: [
                  for (var point in listenables.polygon)
                    DragMarker(
                      size: const Size(30, 30),
                      point: point,
                      alignment: Alignment.topCenter,
                      builder: (_, coords, b) => GestureDetector(
                          onSecondaryTap: () => setState(() {
                                if (listenables.polygon.contains(point)) {
                                  listenables.polygon.remove(point);
                                }
                              }),
                          child: const Icon(Icons.place, size: 30)),
                      onDragUpdate: (details, latLng) => {
                        if (listenables.polygon.contains(point))
                          {
                            listenables.polygon[
                                listenables.polygon.indexOf(point)] = latLng
                          }
                      },
                    ),
                ]),
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Autocomplete<MapSearchLocation>(
                        optionsBuilder: (textEditingValue) {
                          return Future.delayed(_debounce, () async {
                            _onSearchChanged(textEditingValue.text,
                                (locations) => locations);
                            return _searchLocations;
                          });
                        },
                        onSelected: (option) =>
                            mapController.move(option.location, 12),
                        optionsViewBuilder: (context, onSelected, options) {
                          return Align(
                              alignment: Alignment.topLeft,
                              child: Material(
                                  elevation: 4.0,
                                  child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                          maxHeight: 200, maxWidth: 600),
                                      child: ListView.builder(
                                        padding: EdgeInsets.zero,
                                        shrinkWrap: true,
                                        itemCount: options.length,
                                        itemBuilder:
                                            (BuildContext context, int index) {
                                          final option =
                                              options.elementAt(index);
                                          return InkWell(
                                            onTap: () {
                                              onSelected(option);
                                            },
                                            child: Builder(builder:
                                                (BuildContext context) {
                                              final bool highlight =
                                                  AutocompleteHighlightedOption
                                                          .of(context) ==
                                                      index;
                                              if (highlight) {
                                                SchedulerBinding.instance
                                                    .addPostFrameCallback(
                                                        (Duration timeStamp) {
                                                  Scrollable.ensureVisible(
                                                      context,
                                                      alignment: 0.5);
                                                });
                                              }
                                              return Container(
                                                color: highlight
                                                    ? Theme.of(context)
                                                        .focusColor
                                                    : null,
                                                padding:
                                                    const EdgeInsets.all(16.0),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      option.name,
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }),
                                          );
                                        },
                                      ))));
                        },
                        displayStringForOption: (option) => option.name,
                        fieldViewBuilder: (context, textEditingController,
                                focusNode, onFieldSubmitted) =>
                            TextFormField(
                          controller: textEditingController,
                          focusNode: focusNode,
                          onFieldSubmitted: (value) async {
                            await _search(textEditingController.text);
                            mapController.move(
                                _searchLocations.first.location, 12);
                          },
                          decoration: InputDecoration(
                              hintText: 'Search location',
                              border: const OutlineInputBorder(),
                              filled: true,
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () => textEditingController.clear(),
                              ),
                              fillColor: Theme.of(context).colorScheme.surface),
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => setState(() {
                                    listenables.polygon.clear();
                                    _photoMarkers.clear();
                                  }),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Icon(
                                  Icons.clear,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                              )),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
              flex: 1,
              child: Column(
                children: [
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(icon: Icon(Icons.info_outline), text: 'Info'),
                      Tab(icon: Icon(Icons.airplanemode_on), text: 'Aircraft'),
                      Tab(icon: Icon(Icons.photo_camera), text: 'Camera'),
                      Tab(icon: Icon(Icons.save_alt), text: 'Export'),
                    ],
                  ),
                  Expanded(
                      child: TabBarView(
                          controller: _tabController,
                          children: const [
                        Info(),
                        AircraftBar(),
                        CameraBar(),
                        ExportBar()
                      ]))
                ],
              ))
        ];
        return Scaffold(
            appBar: const MappingAppBar(),
            body: MediaQuery.of(context).size.width < 700
                ? Column(
                    children: children,
                  )
                : Row(children: children));
      },
    );
  }
}

class MapSearchLocation {
  final String name;
  final String type;
  final LatLng location;

  MapSearchLocation(
      {required this.name, required this.type, required this.location});
}
