/*
  search_ucac5 - match a list of sky positions against a local copy of UCAC5.

  This is the search engine behind the UCAC5 online search service that
  VaST (https://github.com/kirxkirx/vast) uses for plate solving when it has
  no local copy of the catalog. It is started by cgi-bin/ucac5/search_ucac5.py.

  Usage:
    search_ucac5 CATALOG_DIR BRIGHT_MAG FAINT_MAG RADIUS_ARCSEC < positions > matches
    search_ucac5 --version

  CATALOG_DIR holds the 900 binary UCAC5 zone files z001 ... z900
  (https://cdsarc.cds.unistra.fr/ftp/I/340/readmeU5.txt).
  The input is a list of "RA Dec" pairs in degrees, one pair per line;
  only the first MAX_STARS valid pairs are used.
  The output starts with a comment line ("# ...") carrying the program
  version, followed by one line per matched input position:

    input_RA input_Dec distance_arcsec cat_RA cat_Dec cat_mag epoch pmRA pmDE

  with the catalog position in degrees at the catalog epoch (Julian year)
  and the proper motion (pmRA*cos(Dec), pmDE) in mas/yr. When several
  catalog stars fall within the search radius, the brightest one is taken.

  The matching routine comes from VaST (src/solve_plate_with_UCAC5.c,
  search_UCAC5_localcopy). The zone files are read as stored (little-endian),
  so this program has to run on a little-endian machine.

  This program is free software: you can redistribute it and/or modify it
  under the terms of the GNU General Public License as published by the Free
  Software Foundation, either version 3 of the License, or (at your option)
  any later version. See the file COPYING.
*/

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Set by the Makefile from "git describe"
#ifndef UCAC5_SEARCH_VERSION
#define UCAC5_SEARCH_VERSION "unknown"
#endif

#define MAX_STARS 1000
#define MAX_STARS_IN_LOCAL_CAT_QUERY MAX_STARS

#define UCAC5_NUMBER_OF_ZONES 900
#define UCAC5_ZONE_HEIGHT_DEG 0.2

#define MAX_CATALOG_DIR_LENGTH 4000
#define MAX_ZONE_FILENAME_LENGTH 4096

//// Auxiliary definitions ////
#define MAX( a, b ) ( ( ( a ) > ( b ) ) ? ( a ) : ( b ) )
#define MIN( a, b ) ( ( ( a ) < ( b ) ) ? ( a ) : ( b ) )

struct str_catalog_search_parameters {
 double search_radius_deg;
 double brightest_mag;
 double faintest_mag;
};

struct detected_star {
 double ra_deg_measured;
 double dec_deg_measured;
 int good_star;
 int matched_with_astrometric_catalog;
 double match_distance_astrometric_catalog_arcsec;
 double catalog_ra;
 double catalog_dec;
 double catalog_mag;
 double catalog_epoch;
 double catalog_pmRA;
 double catalog_pmDE;
};

static double compute_distance_on_sphere( double RA1_deg, double DEC1_deg, double RA2_deg, double DEC2_deg ) {
 double distance;
 double deg2rad_conversion= M_PI / 180.0;
 double RA1_rad= RA1_deg * deg2rad_conversion;
 double DEC1_rad= DEC1_deg * deg2rad_conversion;
 double RA2_rad= RA2_deg * deg2rad_conversion;
 double DEC2_rad= DEC2_deg * deg2rad_conversion;

 double cos_DEC1_rad= cos( DEC1_rad );
 double sin_DEC1_rad= sin( DEC1_rad );
 double cos_DEC2_rad= cos( DEC2_rad );
 double sin_DEC2_rad= sin( DEC2_rad );

 distance= acos( cos_DEC1_rad * cos_DEC2_rad * cos( MAX( RA1_rad, RA2_rad ) - MIN( RA1_rad, RA2_rad ) ) + sin_DEC1_rad * sin_DEC2_rad ) / deg2rad_conversion;

 return distance;
}

// Read one field of a zone-file record; leave the record-reading loop at the end of the file (or on a read error)
#define READ_FIELD_OR_BREAK( field ) \
 if ( 1 != fread( &( field ), sizeof( field ), 1, ptr ) ) { \
  break; \
 }

// Returns 0 on success, 1 if the catalog is not found, 2 on an input/output error while reading it.
static int search_UCAC5_localcopy( struct detected_star *stars, int N, struct str_catalog_search_parameters *catalog_search_parameters, const char *catalog_dir ) {

 double faintest_mag, brightest_mag;

 double measured_ra, measured_dec;
 double distance;
 int N_stars_matched_with_astrometric_catalog= 0;

 int search_stars_counter;

 double search_ra_min_deg, search_ra_max_deg;
 double search_dec_min_deg, search_dec_max_deg, search_dec_maxmin_deg, search_dec_mean_deg;
 int ra_wraps;
 double ra_gap_start, ra_gap_end;
 int detected_star_counter;
 unsigned int zone_start, zone_end;

 unsigned int zone_counter;
 char zonefilename[MAX_ZONE_FILENAME_LENGTH];

 int n_zone_files_with_errors= 0;

 double ucac_ra_deg, ucac_dec_deg;
 double ucac_mag;
 double ucac_epoch;

 double ucac_pm_ra_masy;
 double ucac_pm_dec_masy;

 // One record of a UCAC5 zone file is 52 bytes, see readmeU5.txt
 int64_t srcid;
 int32_t ira, idc, rag, dcg;
 int16_t epi, pmir, pmid, pmer, pmed, phgm, im1, rmag, jmag, hmag, kmag, erg, edg;
 int8_t flg, nu1;

 FILE *ptr;

 // Check if a local copy of UCAC5 is found
 snprintf( zonefilename, MAX_ZONE_FILENAME_LENGTH, "%s/z%03d", catalog_dir, 1 );
 ptr= fopen( zonefilename, "rb" );
 if ( NULL == ptr ) {
  fprintf( stderr, "ERROR: no local copy of UCAC5 is found: cannot open %s\n", zonefilename );
  return 1;
 }
 fclose( ptr );

 if ( N < 1 ) {
  fprintf( stderr, "No input positions - nothing to search for.\n" );
  return 0;
 }

 // set zone search parameters
 search_ra_min_deg= 360.0;
 search_ra_max_deg= 0.0;
 search_dec_min_deg= 90.0;
 search_dec_max_deg= -90.0;
 for ( detected_star_counter= 0; detected_star_counter < N; detected_star_counter++ ) {
  if ( stars[detected_star_counter].ra_deg_measured < search_ra_min_deg )
   search_ra_min_deg= stars[detected_star_counter].ra_deg_measured;
  if ( stars[detected_star_counter].ra_deg_measured > search_ra_max_deg )
   search_ra_max_deg= stars[detected_star_counter].ra_deg_measured;
  if ( stars[detected_star_counter].dec_deg_measured < search_dec_min_deg )
   search_dec_min_deg= stars[detected_star_counter].dec_deg_measured;
  if ( stars[detected_star_counter].dec_deg_measured > search_dec_max_deg )
   search_dec_max_deg= stars[detected_star_counter].dec_deg_measured;
 }
 // we don't want search_dec_maxmin_deg to be zero if we are searching for a single star
 search_dec_maxmin_deg= MAX( search_dec_max_deg - search_dec_min_deg, 1.0 / 3600.0 );
 search_dec_mean_deg= ( search_dec_max_deg + search_dec_min_deg ) / 2.0;

 // Detect RA wrapping: if the RA range is > 180 degrees, the field straddles the RA=0/360 boundary
 ra_wraps= 0;
 ra_gap_start= 0.0;
 ra_gap_end= 0.0;
 if ( search_ra_max_deg - search_ra_min_deg > 180.0 ) {
  ra_wraps= 1;
  // Compute the gap boundaries: the gap is the RA range NOT covered by the field
  // ra_gap_start = max RA among stars with RA < 180 (upper edge of the low-RA group)
  // ra_gap_end = min RA among stars with RA >= 180 (lower edge of the high-RA group)
  ra_gap_start= 0.0;
  ra_gap_end= 360.0;
  for ( detected_star_counter= 0; detected_star_counter < N; detected_star_counter++ ) {
   if ( stars[detected_star_counter].ra_deg_measured < 180.0 ) {
    if ( stars[detected_star_counter].ra_deg_measured > ra_gap_start ) {
     ra_gap_start= stars[detected_star_counter].ra_deg_measured;
    }
   } else {
    if ( stars[detected_star_counter].ra_deg_measured < ra_gap_end ) {
     ra_gap_end= stars[detected_star_counter].ra_deg_measured;
    }
   }
  }
  fprintf( stderr, "RA wraps around 0/360 boundary: field RA %.4f through 0 to %.4f, gap %.4f to %.4f\n", ra_gap_end, ra_gap_start, ra_gap_start, ra_gap_end );
 }

 faintest_mag= catalog_search_parameters->faintest_mag;
 brightest_mag= catalog_search_parameters->brightest_mag;

 // Select only the relevant zone files based on declination
 // Each zone covers 0.2 degrees: zone 1 = Dec -90.0 to -89.8, zone 900 = Dec +89.8 to +90.0
 zone_start= (unsigned int)( ( search_dec_min_deg + 90.0 ) / UCAC5_ZONE_HEIGHT_DEG ) + 1;
 zone_end= (unsigned int)( ( search_dec_max_deg + 90.0 ) / UCAC5_ZONE_HEIGHT_DEG ) + 1;
 if ( zone_start > 1 ) {
  zone_start--;
 }
 zone_end++;
 if ( zone_start < 1 ) {
  zone_start= 1;
 }
 if ( zone_end > UCAC5_NUMBER_OF_ZONES ) {
  zone_end= UCAC5_NUMBER_OF_ZONES;
 }
 fprintf( stderr, "Searching UCAC5 zones %u to %u (Dec %.1f to %.1f)\n", zone_start, zone_end, search_dec_min_deg, search_dec_max_deg );

 // Read each zone file
 for ( zone_counter= zone_start; zone_counter <= zone_end; zone_counter++ ) {

  snprintf( zonefilename, MAX_ZONE_FILENAME_LENGTH, "%s/z%03u", catalog_dir, zone_counter );

  ptr= fopen( zonefilename, "rb" );
  if ( NULL == ptr ) {
   if ( errno == ENOENT ) {
    // a zone file that does not exist is skipped, as before
    fprintf( stderr, "WARNING: zone file %s does not exist\n", zonefilename );
   } else {
    fprintf( stderr, "ERROR opening zone file %s: %s\n", zonefilename, strerror( errno ) );
    n_zone_files_with_errors++;
   }
   continue;
  }

  // Read all stars in the zone file
  while ( 1 == 1 ) {
   READ_FIELD_OR_BREAK( srcid );
   READ_FIELD_OR_BREAK( rag );
   READ_FIELD_OR_BREAK( dcg );
   READ_FIELD_OR_BREAK( erg );
   READ_FIELD_OR_BREAK( edg );
   READ_FIELD_OR_BREAK( flg );
   READ_FIELD_OR_BREAK( nu1 );
   READ_FIELD_OR_BREAK( epi );
   ucac_epoch= (double)epi / 1000.0 + 1997.0;
   READ_FIELD_OR_BREAK( ira );
   READ_FIELD_OR_BREAK( idc );
   ucac_ra_deg= (double)ira / 3600000.0;
   ucac_dec_deg= (double)idc / 3600000.0;
   if ( fabs( search_dec_mean_deg - ucac_dec_deg ) > search_dec_maxmin_deg / 2.0 + 0.2 ) {
    break;
   }
   READ_FIELD_OR_BREAK( pmir );
   READ_FIELD_OR_BREAK( pmid );
   READ_FIELD_OR_BREAK( pmer );
   READ_FIELD_OR_BREAK( pmed );
   ucac_pm_ra_masy= 0.1 * (double)pmir;
   ucac_pm_dec_masy= 0.1 * (double)pmid;
   READ_FIELD_OR_BREAK( phgm );
   READ_FIELD_OR_BREAK( im1 );
   ucac_mag= (double)im1 / 1000.0;
   READ_FIELD_OR_BREAK( rmag );
   READ_FIELD_OR_BREAK( jmag );
   READ_FIELD_OR_BREAK( hmag );
   READ_FIELD_OR_BREAK( kmag );

   // Check the search parameters
   if ( ucac_mag > faintest_mag ) {
    continue;
   }
   if ( ucac_mag < brightest_mag ) {
    continue;
   }
   // RA filter with wrapping support
   if ( ra_wraps ) {
    // Field straddles RA=0/360: reject stars in the gap
    if ( ucac_ra_deg > ra_gap_start && ucac_ra_deg < ra_gap_end ) {
     continue;
    }
   } else {
    if ( ucac_ra_deg < search_ra_min_deg ) {
     continue;
    }
    if ( ucac_ra_deg > search_ra_max_deg ) {
     continue;
    }
   }
   if ( ucac_dec_deg < search_dec_min_deg ) {
    continue;
   }
   if ( ucac_dec_deg > search_dec_max_deg ) {
    continue;
   }
   //
   // Go through all the detected stars and search for a match
   search_stars_counter= 0;
   for ( detected_star_counter= 0; detected_star_counter < N; detected_star_counter++ ) {
    if ( stars[detected_star_counter].good_star != 1 ) {
     continue;
    }
    if ( search_stars_counter == MAX_STARS_IN_LOCAL_CAT_QUERY ) {
     break;
    }
    search_stars_counter++;
    measured_ra= stars[detected_star_counter].ra_deg_measured;
    measured_dec= stars[detected_star_counter].dec_deg_measured;
    distance= compute_distance_on_sphere( ucac_ra_deg, ucac_dec_deg, measured_ra, measured_dec );
    if ( distance < catalog_search_parameters->search_radius_deg ) {
     if ( ( ucac_mag < stars[detected_star_counter].catalog_mag && stars[detected_star_counter].matched_with_astrometric_catalog == 1 ) || stars[detected_star_counter].matched_with_astrometric_catalog == 0 ) {
      if ( stars[detected_star_counter].matched_with_astrometric_catalog == 0 ) {
       N_stars_matched_with_astrometric_catalog++;
      }
      stars[detected_star_counter].catalog_epoch= ucac_epoch;
      stars[detected_star_counter].catalog_pmRA= ucac_pm_ra_masy;
      stars[detected_star_counter].catalog_pmDE= ucac_pm_dec_masy;
      stars[detected_star_counter].matched_with_astrometric_catalog= 1;
      stars[detected_star_counter].catalog_ra= ucac_ra_deg;
      stars[detected_star_counter].catalog_dec= ucac_dec_deg;
      stars[detected_star_counter].catalog_mag= ucac_mag;
      stars[detected_star_counter].match_distance_astrometric_catalog_arcsec= distance * 3600;
      break;
     }
    }
   }
  }

  // The loop above also ends on a read error: a failing disk must not look like "no matches"
  if ( ferror( ptr ) ) {
   fprintf( stderr, "ERROR reading zone file %s\n", zonefilename );
   n_zone_files_with_errors++;
  }

  fclose( ptr );
 }

 if ( n_zone_files_with_errors > 0 ) {
  fprintf( stderr, "ERROR: input/output errors on %d UCAC5 zone file(s) in %s - the storage device may be failing or disconnected!\n", n_zone_files_with_errors, catalog_dir );
  return 2;
 }

 fprintf( stderr, "Matched %d stars with the local copy of UCAC5.\n", N_stars_matched_with_astrometric_catalog );

 return 0;
}

static void print_version_line( FILE *output ) {
 fprintf( output, "# UCAC5 online search %s\n", UCAC5_SEARCH_VERSION );
}

// Convert a command-line argument to a finite number; returns 0 on success
static int string_to_finite_double( const char *string, double *value ) {
 char *endptr;
 errno= 0;
 *value= strtod( string, &endptr );
 if ( endptr == string || *endptr != '\0' || errno != 0 ) {
  return 1;
 }
 if ( !isfinite( *value ) ) {
  return 1;
 }
 return 0;
}

int main( int argc, char **argv ) {
 static struct detected_star stars[MAX_STARS];
 struct str_catalog_search_parameters catalog_search_parameters;
 const char *catalog_dir;
 double search_radius_arcsec;
 double ra, dec;
 uint16_t endianness_test= 1;
 int search_status;
 int N= 0;
 int i;

 if ( argc == 2 && 0 == strcmp( argv[1], "--version" ) ) {
  print_version_line( stdout );
  return 0;
 }

 if ( argc != 5 ) {
  fprintf( stderr, "Usage: %s CATALOG_DIR BRIGHT_MAG FAINT_MAG RADIUS_ARCSEC < positions > matches\n       %s --version\n", argv[0], argv[0] );
  return 1;
 }

 if ( *(unsigned char *)&endianness_test != 1 ) {
  fprintf( stderr, "ERROR: this program reads the little-endian UCAC5 zone files as they are and cannot run on a big-endian machine\n" );
  return 1;
 }

 catalog_dir= argv[1];
 if ( strlen( catalog_dir ) < 1 || strlen( catalog_dir ) > MAX_CATALOG_DIR_LENGTH ) {
  fprintf( stderr, "ERROR: bad catalog directory name\n" );
  return 1;
 }
 if ( 0 != string_to_finite_double( argv[2], &catalog_search_parameters.brightest_mag ) || 0 != string_to_finite_double( argv[3], &catalog_search_parameters.faintest_mag ) || 0 != string_to_finite_double( argv[4], &search_radius_arcsec ) ) {
  fprintf( stderr, "ERROR: BRIGHT_MAG, FAINT_MAG and RADIUS_ARCSEC should be numbers\n" );
  return 1;
 }
 catalog_search_parameters.search_radius_deg= search_radius_arcsec / 3600;

 // Read the input positions, silently skipping the impossible ones
 memset( stars, 0, sizeof( stars ) );
 while ( N < MAX_STARS && 2 == fscanf( stdin, "%lf %lf", &ra, &dec ) ) {
  if ( !( ra >= 0.0 && ra <= 360.0 && dec >= -90.0 && dec <= 90.0 ) ) {
   continue;
  }
  stars[N].ra_deg_measured= ra;
  stars[N].dec_deg_measured= dec;
  stars[N].good_star= 1;
  stars[N].matched_with_astrometric_catalog= 0;
  N++;
 }

 search_status= search_UCAC5_localcopy( stars, N, &catalog_search_parameters, catalog_dir );
 if ( search_status != 0 ) {
  return search_status;
 }

 print_version_line( stdout );
 for ( i= 0; i < N; i++ ) {
  if ( stars[i].matched_with_astrometric_catalog ) {
   printf( "%lf %lf %lf %lf %lf %lf %lf %lf %lf\n",
           stars[i].ra_deg_measured, stars[i].dec_deg_measured, stars[i].match_distance_astrometric_catalog_arcsec,
           stars[i].catalog_ra, stars[i].catalog_dec, stars[i].catalog_mag,
           stars[i].catalog_epoch, stars[i].catalog_pmRA, stars[i].catalog_pmDE );
  }
 }

 if ( 0 != fflush( stdout ) || ferror( stdout ) ) {
  fprintf( stderr, "ERROR writing the results\n" );
  return 2;
 }

 return 0;
}
