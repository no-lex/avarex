import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:avaremp/storage.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'package:avaremp/destination/destination.dart';
import 'package:avaremp/saa.dart';
import 'cifp.dart';

class MainDatabaseHelper {
  MainDatabaseHelper._();

  static final MainDatabaseHelper _db = MainDatabaseHelper._();

  static MainDatabaseHelper get db => _db;
  static Database? _database;

  static const String _limit = "20"; // limit results

  Future<Database?> get database async {
    if (_database != null) {
      return _database;
    }
    _database = await _initDB();
    return _database;
  }

  _initDB() async {
    Directory documentsDirectory = Directory(Storage().dataDir);
    String path = join(documentsDirectory.path, "main.db");
    return
      await openDatabase(path, onOpen: (db) {});
  }

  Future<List<LatLng>> findObstacles(LatLng point, double altitude) async {
    final db = await database;
    if (db != null) {
      String qry = "select ARPLatitude, ARPLongitude, Height from obs where (Height > ${altitude - 200}) and (ARPLatitude > ${point.latitude - 0.4}) and (ARPLatitude < ${point.latitude + 0.4}) and (ARPLongitude > ${point.longitude - 0.4}) and (ARPLongitude < ${point.longitude + 0.4})";
      return db.rawQuery(qry).then((maps) {
        return List.generate(maps.length, (i) {
          return LatLng(maps[i]['ARPLatitude'] as double, maps[i]['ARPLongitude'] as double);
        });
      });
    }

    return [];

  }

  Future<List<Destination>> findDestinations(String match) async {
    List<Map<String, dynamic>> maps = [];
    List<Map<String, dynamic>> mapsAirways = [];
    if(match.startsWith("!") && match.endsWith("!")) {
      //address between ! and !
      String address = match.substring(1, match.length - 1);
      LatLng? coordinate = await Destination.findGpsCoordinateFromAddressLookup(address);
      if(coordinate != null) {
        return [GpsDestination(locationID: Destination.formatSexagesimal(coordinate.toSexagesimal()), type: Destination.typeGps, facilityName: address, coordinate: coordinate)];
      }
    }
    if(match.contains("@")) {
      // parse sexagesimal coordinate like my location @ 34 12 34 N 118 12 34 W
      List<String> parts = match.split("@");
      LatLng coordinate = Destination.parseFromSexagesimalFullOrPartial(parts[1]);
      return [GpsDestination(locationID: Destination.formatSexagesimal(coordinate.toSexagesimal()), type: Destination.typeGps, facilityName: parts[0], coordinate: coordinate)];
    }
    final db = await database;
    if (db != null) {
      maps = await db.rawQuery(
        // combine airports, fix, nav that matches match word and return 3 columns to show in the find result
          "      select LocationID, FacilityName, Type, ARPLongitude, ARPLatitude from airports where (LocationID like '$match%') "
          "union select LocationID, FacilityName, Type, ARPLongitude, ARPLatitude from nav      where (LocationID like '$match%') "
          "union select LocationID, FacilityName, Type, ARPLongitude, ARPLatitude from fix      where (LocationID like '$match%') "
          "order by Type asc limit $_limit"
      );
      mapsAirways = await db.rawQuery(
          "select name, sequence, Longitude, Latitude from airways where name = '$match' COLLATE NOCASE "
              "order by cast(sequence as integer) asc limit 1"
      );
    }

    List<Destination> ret = List.generate(maps.length, (i) {
      return Destination.fromMap(maps[i]);
    });


    if(mapsAirways.isNotEmpty) {
      Destination d = Destination(
          locationID: mapsAirways[0]['name'] as String,
          facilityName: mapsAirways[0]['name'] as String,
          type: Destination.typeAirway,
          coordinate: LatLng(mapsAirways[0]['Latitude'] as double, mapsAirways[0]['Longitude'] as double),
        );
      ret.add(d);
    }

    return ret;
  }

  Future<Destination> findDestinationByCoordinates(LatLng point, {double factor = 0.001}) async {

    final db = await database;
    if (db != null) {
      num corrFactor = pow(cos(point.latitude * pi / 180.0), 2);
      String asDistance = "((ARPLongitude - ${point
          .longitude}) * (ARPLongitude - ${point.longitude}) * ${corrFactor
          .toDouble()} + (ARPLatitude - ${point
          .latitude}) * (ARPLatitude - ${point.latitude}))";

      String qry =
          "      select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from airports where distance < $factor "
          "union select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from nav      where distance < $factor "
          "union select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from fix      where distance < $factor "
          "order by distance asc limit 1";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);
      if(maps.isNotEmpty) {
        return Destination.fromMap(maps[0]);
      }
    }
    // always add touch point of GPS, GPS is not a database type so prefix with _
    String gps = Destination.formatSexagesimal(point.toSexagesimal());
    return(Destination(locationID: gps, type: Destination.typeGps, facilityName: Destination.typeGps, coordinate: point));
  }

  Future<List<Destination>> findNear(LatLng point, {double factor = 0.001}) async {
    final db = await database;
    List<Destination> ret = [];
    if (db != null) {
      num corrFactor = pow(cos(point.latitude * pi / 180.0), 2);
      String asDistance = "((ARPLongitude - ${point
          .longitude}) * (ARPLongitude - ${point.longitude}) * ${corrFactor
          .toDouble()} + (ARPLatitude - ${point
          .latitude}) * (ARPLatitude - ${point.latitude}))";

      String qry =
          "      select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from airports where distance < $factor and (Type = 'AIRPORT' or Type = 'SEAPLANE BAS') " // only what shows on chart
          "union select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from nav      where distance < $factor "
          "union select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from fix      where distance < $factor "
          "order by Type asc, distance asc limit $_limit";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);

      ret = List.generate(maps.length, (i) {
        return Destination.fromMap(maps[i]);
      });
    }
    // always add touch point of GPS, GPS is not a database type so prefix with _
    String gps = Destination.formatSexagesimal(point.toSexagesimal());
    ret.add(Destination(locationID: gps, type: Destination.typeGps, facilityName: Destination.typeGps, coordinate: point));
    return(ret);
  }

  Future<List<Saa>> getSaa(LatLng point) async {
    final db = await database;
    List<Saa> ret = [];
    if (db != null) {
      num corrFactor = pow(cos(point.latitude * pi / 180.0), 2);
      String asDistance = "((lon - ${point
          .longitude}) * (lon - ${point.longitude}) * ${corrFactor
          .toDouble()} + (lat - ${point
          .latitude}) * (lat - ${point.latitude}))";

      String qry = "select designator, name, FreqTx, FreqRx, day, lat, lon, $asDistance as distance from saa where distance < 1 order by distance asc limit $_limit";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);

      ret = List.generate(maps.length, (i) {
        return Saa.fromMap(maps[i]);
      });
    }
    return(ret);
  }

  Future<String> getFaaName(String icao) async {
    final db = await database;
    if (db != null) {
      String qry = "select FaaID from airports where LocationID = '$icao'";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);
      if(maps.isNotEmpty) {
        return maps[0]['FaaID'] as String;
      }
    }
    return icao;
  }

  Future<List<Destination>> findNearestAirportsWithRunways(LatLng point, int runwayLength) async {
    final db = await database;
    List<Destination> ret = [];
    if (db != null) {
      num corrFactor = pow(cos(point.latitude * pi / 180.0), 2);
      String asDistance = "((ARPLongitude - ${point
          .longitude}) * (ARPLongitude - ${point.longitude}) * ${corrFactor
          .toDouble()} + (ARPLatitude - ${point
          .latitude}) * (ARPLatitude - ${point.latitude}))";

      String qry =
          "select airports.LocationID, airports.DLID, airports.FacilityName, airports.Type, airports.ARPLongitude, airports.ARPLatitude, airportrunways.Length, $asDistance as distance from airports "
          "left join airportrunways where "
          "airports.DLID = airportrunways.DLID and airports.Type='AIRPORT' and cast (airportrunways.Length as INTEGER) >= $runwayLength "
          "order by distance asc limit $_limit";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);

      List<String> duplicates = [];
      // get rid of duplicates
      for(Map<String, dynamic> map in maps) {
        if(duplicates.contains(map['LocationID'])) {
          continue;
        }
        ret.add(Destination.fromMap(map));
        duplicates.add(map['LocationID']);
      }

    }
    return(ret);
  }

  Future<Destination> findNearNavOrFixElseGps(LatLng point, {double factor = 0.001}) async {
    final db = await database;
    if (db != null) {
      num corrFactor = pow(cos(point.latitude * pi / 180.0), 2);
      String asDistance = "((ARPLongitude - ${point
          .longitude}) * (ARPLongitude - ${point.longitude}) * ${corrFactor
          .toDouble()} + (ARPLatitude - ${point
          .latitude}) * (ARPLatitude - ${point.latitude}))";

      String qry =
          "      select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from nav      where distance < $factor "
          "union select LocationID, ARPLatitude, ARPLongitude, FacilityName, Type, $asDistance as distance from fix      where distance < $factor "
          "order by distance asc limit 1";
      List<Map<String, dynamic>> maps = await db.rawQuery(qry);

      return Destination.fromMap(maps[0]);
    }
    // always add touch point of GPS, GPS is not a database type so prefix with _
    String gps = Destination.formatSexagesimal(point.toSexagesimal());
    return Destination(locationID: gps, type: Destination.typeGps, facilityName: Destination.typeGps, coordinate: point);
  }

  Future<AirportDestination?> findAirport(String airport) async {
    List<Map<String, dynamic>> mapsAirports = [];
    List<Map<String, dynamic>> mapsFreq = [];
    List<Map<String, dynamic>> mapsRunways = [];
    List<Map<String, dynamic>> mapsAwos = [];
    final db = await database;
    if (db != null) {
      mapsAirports = await db.rawQuery("select * from airports       where LocationID = '$airport'");
      if(mapsAirports.isEmpty) {
        return null;
      }
      String dlid = mapsAirports[0]['DLID'] as String;
      mapsFreq = await db.rawQuery(    "select * from airportfreq    where DLID = '$dlid'");
      mapsRunways = await db.rawQuery( "select * from airportrunways where DLID = '$dlid'");
      mapsAwos = await db.rawQuery(    "select * from awos           where DLID = '$dlid'");
      return AirportDestination.fromMap(mapsAirports[0], mapsFreq, mapsAwos, mapsRunways);
    }

    return null;
  }

  Future<NavDestination?> findNav(String nav) async {
    List<Map<String, dynamic>> maps = [];
    final db = await database;
    if (db != null) {
      maps = await db.rawQuery("select * from nav where LocationID = '$nav'");
    }
    if(maps.isEmpty) {
      return null;
    }

    return NavDestination.fromMap(maps[0]);
  }

  Future<FixDestination?> findFix(String fix) async {
    List<Map<String, dynamic>> maps = [];
    final db = await database;
    if (db != null) {
      maps = await db.rawQuery("select * from fix where LocationID = '$fix'");
    }
    if(maps.isEmpty) {
      return null;
    }

    return FixDestination.fromMap(maps[0]);
  }

  Future<AirwayDestination?> findAirway(String airway) async {
    List<Map<String, dynamic>> maps = [];
    final db = await database;
    if (db != null) {
      maps = await db.rawQuery("select name, sequence, Longitude, Latitude from airways where name = '$airway' COLLATE NOCASE "
          "order by cast(sequence as integer) asc");
    }
    if(maps.isEmpty) {
      return null;
    }

    return AirwayDestination.fromMap(maps);
  }

  Future<List<CifpSidStarApproachLine>> findCifpStar(String airport, String id, String transition) async {
    List<Map<String, dynamic>> maps = [];
    final db = await database;
    if (db != null) {
      String qry = "select * from cifp_sid_star_app where trim(airport_identifier) = '$airport' and trim(sid_star_approach_identifier) = '$id' and subsection_code='E' and (trim(transition_identifier)='$transition' or trim(transition_identifier)='ALL')";
      maps = await db.rawQuery(qry);
    }
    return List.generate(maps.length, (i) {
      return CifpSidStarApproachLine.fromMap(maps[i]);
    });
  }

  Future<List<CifpSidStarApproachLine>> findCifpSid(String airport, String id, String transition) async {
    List<Map<String, dynamic>> maps = [];
    final db = await database;
    if (db != null) {
      String qry = "select * from cifp_sid_star_app where trim(airport_identifier) = '$airport' and trim(sid_star_approach_identifier) = '$id' and subsection_code='D' and trim(transition_identifier)='$transition'";
      maps = await db.rawQuery(qry);
    }
    return List.generate(maps.length, (i) {
      return CifpSidStarApproachLine.fromMap(maps[i]);
    });
  }

}


