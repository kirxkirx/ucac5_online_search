#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define MAX_STARS 1000
#define MAX_STARS_IN_LOCAL_CAT_QUERY MAX_STARS

//// Auxiliary definitions ////
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#define MIN(a, b) (((a) < (b)) ? (a) : (b))

struct str_catalog_search_parameters {
 double search_radius_deg;
 double search_radius_second_step_deg;
 double brightest_mag;
 double faintest_mag;
};

struct detected_star {
 int n_current_frame;
 double x_pix;
 double y_pix;
 double ra_deg_measured;
 double dec_deg_measured;
 double flux;
 double flux_err;
 double mag;
 double mag_err;
 int flag;
 double ra_deg_measured_orig;
 double dec_deg_measured_orig;
 int matched_with_astrometric_catalog;
 int matched_with_photometric_catalog;
 double match_distance_astrometric_catalog_arcsec;
 double d_ra;
 double d_dec;
 double computed_d_ra;
 double computed_d_dec;
 double corrected_ra_planefit;
 double corrected_dec_planefit;
 double corrected_mag_ra;
 double corrected_mag_dec;
 double local_correction_ra;
 double local_correction_dec;
 double corrected_ra_local;
 double corrected_dec_local;
 double catalog_ra;
 double catalog_dec;
 double catalog_ra_original;
 double catalog_dec_original;
 double catalog_mag;
 double catalog_mag_err;
 int good_star;
 double catalog_epoch;
 double catalog_pmRA;
 double catalog_pmDE;
 double APASS_B;
 double APASS_B_err;
 double APASS_V;
 double APASS_V_err;
 double APASS_r;
 double APASS_r_err;
 double APASS_i;
 double APASS_i_err;
 double APASS_g;
 double APASS_g_err;
 double Rc_computed_from_APASS_ri;
 double Rc_computed_from_APASS_ri_err;
 double Ic_computed_from_APASS_ri;
 double Ic_computed_from_APASS_ri_err;
 double estimated_local_correction_accuracy;
 double observing_epoch_jd;
};

static inline double compute_distance_on_sphere( double RA1_deg, double DEC1_deg, double RA2_deg, double DEC2_deg ) {
 double distance;
 double deg2rad_conversion= M_PI / 180.0;
 double RA1_rad= RA1_deg * deg2rad_conversion;
 double DEC1_rad= DEC1_deg * deg2rad_conversion;
 double RA2_rad= RA2_deg * deg2rad_conversion;
 double DEC2_rad= DEC2_deg * deg2rad_conversion;

 double cos_DEC1_rad;
 double sin_DEC1_rad;
 double cos_DEC2_rad;
 double sin_DEC2_rad;

#ifdef VAST_USE_SINCOS
 sincos( DEC1_rad, &sin_DEC1_rad, &cos_DEC1_rad );
 sincos( DEC2_rad, &sin_DEC2_rad, &cos_DEC2_rad );
#else
 cos_DEC1_rad= cos( DEC1_rad );
 sin_DEC1_rad= sin( DEC1_rad );
 cos_DEC2_rad= cos( DEC2_rad );
 sin_DEC2_rad= sin( DEC2_rad );
#endif

 distance= acos( cos_DEC1_rad * cos_DEC2_rad * cos( MAX( RA1_rad, RA2_rad ) - MIN( RA1_rad, RA2_rad ) ) + sin_DEC1_rad * sin_DEC2_rad ) / deg2rad_conversion;

 return distance;
}

int search_UCAC5_localcopy( struct detected_star *stars, int N, struct str_catalog_search_parameters *catalog_search_parameters ) {

 double faintest_mag, brightest_mag;

 double observing_epoch_jy, dt;

 double measured_ra, measured_dec, catalog_ra, catalog_dec, catalog_mag;
 double distance;
 double catalog_ra_original, catalog_dec_original;
 double cos_delta;
 int N_stars_matched_with_astrometric_catalog= 0;

 int search_stars_counter;

 double epoch, pmRA, pmDE;

 double search_ra_min_deg, search_ra_max_deg;
 double search_dec_min_deg, search_dec_max_deg, search_dec_maxmin_deg, search_dec_mean_deg;
 int ra_wraps;
 double ra_gap_start, ra_gap_end;
 int detected_star_counter;
 unsigned int zone_start, zone_end;

 unsigned int zone_counter;
 char zonefilename[1024];

 double ucac_ra_deg, ucac_dec_deg;
 double ucac_mag;
 double ucac_epoch;

 double ucac_pm_ra_masy;
 double ucac_pm_dec_masy;

 int64_t srcid;
 int32_t ira, idc, rag, dcg;
 int16_t epi, pmir, pmid, pmer, pmed, phgm, im1, rmag, jmag, hmag, kmag, erg, edg;
 int8_t flg, nu1;

 FILE *ptr;

 // Check if a local copy of UCAC5 is found
 sprintf( zonefilename, "/var/www/ucac5/z%03d", 1 );
 ptr= fopen( zonefilename, "rb" );
 if ( NULL == ptr ) {
  fprintf( stderr, "No local copy of UCAC5 is found\n" );
  return 1;
 } else {
  fprintf( stderr, "Found a local copy of UCAC5\n" );
 }
 fclose( ptr );

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
 search_dec_maxmin_deg= MAX( search_dec_max_deg - search_dec_min_deg, 1.0/3600.0 );
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

 fprintf( stderr, "Reading UCAC5 zone files...\n" );

 // Select only the relevant zone files based on declination
 // Each zone covers 0.2 degrees: zone 1 = Dec -90.0 to -89.8, zone 900 = Dec +89.8 to +90.0
 zone_start= (unsigned int)( ( search_dec_min_deg + 90.0 ) / 0.2 ) + 1;
 zone_end= (unsigned int)( ( search_dec_max_deg + 90.0 ) / 0.2 ) + 1;
 if ( zone_start > 1 ) {
  zone_start--;
 }
 zone_end++;
 if ( zone_start < 1 ) {
  zone_start= 1;
 }
 if ( zone_end > 900 ) {
  zone_end= 900;
 }
 fprintf( stderr, "Searching UCAC5 zones %u to %u (Dec %.1f to %.1f)\n", zone_start, zone_end, search_dec_min_deg, search_dec_max_deg );

 // Read each zone file
 for ( zone_counter= zone_start; zone_counter <= zone_end; zone_counter++ ) {

  sprintf( zonefilename, "/var/www/ucac5/z%03d", zone_counter );

  ptr= fopen( zonefilename, "rb" );
  if ( NULL == ptr ) {
   fprintf( stderr, "ERROR opening zone file %s\n", zonefilename );
   continue;
  }

  // Read all stars in the zone file
  while ( 1 == 1 ) {
   if ( 0 == fread( &srcid, sizeof( srcid ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &rag, sizeof( rag ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &dcg, sizeof( dcg ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &erg, sizeof( erg ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &edg, sizeof( edg ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &flg, sizeof( flg ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &nu1, sizeof( nu1 ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &epi, sizeof( epi ), 1, ptr ) ) {
    break;
   }
   ucac_epoch= (double)epi / 1000.0 + 1997.0;
   epoch= ucac_epoch;
   if ( 0 == fread( &ira, sizeof( ira ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &idc, sizeof( idc ), 1, ptr ) ) {
    break;
   }
   ucac_ra_deg= (double)ira / 3600000.0;
   ucac_dec_deg= (double)idc / 3600000.0;
   if ( fabs( search_dec_mean_deg - ucac_dec_deg ) > search_dec_maxmin_deg / 2.0 + 0.2 ) {
    break;
   }
   if ( 0 == fread( &pmir, sizeof( pmir ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &pmid, sizeof( pmid ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &pmer, sizeof( pmer ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &pmed, sizeof( pmed ), 1, ptr ) ) {
    break;
   }
   ucac_pm_ra_masy= 0.1 * (double)pmir;
   ucac_pm_dec_masy= 0.1 * (double)pmid;
   if ( 0 == fread( &phgm, sizeof( phgm ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &im1, sizeof( im1 ), 1, ptr ) ) {
    break;
   }
   ucac_mag= (double)im1 / 1000.0;
   if ( 0 == fread( &rmag, sizeof( rmag ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &jmag, sizeof( jmag ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &hmag, sizeof( hmag ), 1, ptr ) ) {
    break;
   }
   if ( 0 == fread( &kmag, sizeof( kmag ), 1, ptr ) ) {
    break;
   }

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
      catalog_ra= ucac_ra_deg;
      catalog_dec= ucac_dec_deg;
      pmRA= ucac_pm_ra_masy;
      pmDE= ucac_pm_dec_masy;
      catalog_mag= ucac_mag;
      stars[detected_star_counter].catalog_epoch= epoch;
      stars[detected_star_counter].catalog_pmRA= pmRA;
      stars[detected_star_counter].catalog_pmDE= pmDE;
      stars[detected_star_counter].matched_with_astrometric_catalog= 1;
      stars[detected_star_counter].d_ra= catalog_ra - measured_ra;
      stars[detected_star_counter].d_dec= catalog_dec - measured_dec;
      stars[detected_star_counter].catalog_ra= catalog_ra;
      stars[detected_star_counter].catalog_dec= catalog_dec;
      stars[detected_star_counter].catalog_mag= catalog_mag;
      stars[detected_star_counter].catalog_mag_err= 0.0;
      stars[detected_star_counter].catalog_ra_original= catalog_ra_original;
      stars[detected_star_counter].catalog_dec_original= catalog_dec_original;
      // reset photometric info
      stars[detected_star_counter].APASS_B= 0.0;
      stars[detected_star_counter].APASS_B_err= 0.0;
      stars[detected_star_counter].APASS_V= 0.0;
      stars[detected_star_counter].APASS_V_err= 0.0;
      stars[detected_star_counter].APASS_r= 0.0;
      stars[detected_star_counter].APASS_r_err= 0.0;
      stars[detected_star_counter].APASS_i= 0.0;
      stars[detected_star_counter].APASS_i_err= 0.0;
      stars[detected_star_counter].Rc_computed_from_APASS_ri= 0.0;
      stars[detected_star_counter].Rc_computed_from_APASS_ri_err= 0.0;
      stars[detected_star_counter].Rc_computed_from_APASS_ri_err= 0.0;
      stars[detected_star_counter].Ic_computed_from_APASS_ri= 0.0;
      stars[detected_star_counter].Ic_computed_from_APASS_ri_err= 0.0;
      stars[detected_star_counter].match_distance_astrometric_catalog_arcsec= distance*3600;
      break;
     }
    }
   }
  }

  fclose( ptr );
 }

 fprintf( stderr, "Done reading UCAC5 zone files...\n" );
 fprintf( stderr, "Matched %d stars with the local copy of UCAC5.\n", N_stars_matched_with_astrometric_catalog );

 return 0;
}

int main(int argc, char **argv) {
    FILE *inputFile, *outputFile;
    struct detected_star stars[MAX_STARS];
    struct str_catalog_search_parameters catalog_search_parameters = {.faintest_mag = 100, .brightest_mag = 0, .search_radius_deg = 1.0/3600};
    int N = 0;
    int i;

    if( argc<4 ){
     fprintf(stderr, "Usage: %s brightmag fainmag searchradiusarcsec\n", argv[0]);
     return 1;
    }
    catalog_search_parameters.brightest_mag=atof(argv[1]);
    catalog_search_parameters.faintest_mag=atof(argv[2]);
    catalog_search_parameters.search_radius_deg=atof(argv[3])/3600;

    inputFile = fopen("input.txt", "r");
    if (inputFile == NULL) {
        perror("Unable to open input file");
        exit(EXIT_FAILURE);
    }

    while (fscanf(inputFile, "%lf %lf", &stars[N].ra_deg_measured, &stars[N].dec_deg_measured) == 2) {
        stars[N].good_star = 1;
        stars[N].matched_with_astrometric_catalog = 0;
        N++;
        if (N == MAX_STARS) break;
    }

    fclose(inputFile);

    if (search_UCAC5_localcopy(stars, N, &catalog_search_parameters) != 0) {
        exit(EXIT_FAILURE);
    }

    outputFile = fopen("output.txt", "w");
    if (outputFile == NULL) {
        perror("Unable to open output file");
        exit(EXIT_FAILURE);
    }

    for (i = 0; i < N; i++) {
        if (stars[i].matched_with_astrometric_catalog) {
            fprintf(outputFile, "%lf %lf %lf %lf %lf %lf %lf %lf %lf\n",
                    stars[i].ra_deg_measured, stars[i].dec_deg_measured, stars[i].match_distance_astrometric_catalog_arcsec,
                    stars[i].catalog_ra, stars[i].catalog_dec, stars[i].catalog_mag,
                    stars[i].catalog_epoch, stars[i].catalog_pmRA, stars[i].catalog_pmDE);
        }
    }

    fclose(outputFile);
    return 0;
}
