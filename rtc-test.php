<?php
/**
 * Plugin Name: RTC Test
 * Description: Load-test monitor and session capture for the WordPress RTC HTTP polling endpoint.
 *              Monitor: records per-request timing, CPU, query, and concurrency metrics (tagged requests).
 *              Capture: records real Gutenberg browser sessions as replay fixtures.
 * Version: 1.0.0
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

// Capture CPU state as early as possible in the request lifecycle.
// getrusage() returns cumulative user+system CPU for this FPM worker process;
// we always use it as a delta (end - start) so the cumulative baseline does not
// matter. Stored in a global so rtctest_post_dispatch can compute total request
// CPU (WP bootstrap + auth + routing + dispatch) rather than dispatch-only.
//
// PHP-FPM re-executes wp-settings.php (and therefore this file) from scratch
// on every request, so this captures the start of each individual request.
$_rtctest_ru             = getrusage();
$GLOBALS['rtctest_boot_cpu'] = (int) $_rtctest_ru['ru_utime.tv_sec'] * 1000000 + (int) $_rtctest_ru['ru_utime.tv_usec']
                             + (int) $_rtctest_ru['ru_stime.tv_sec'] * 1000000 + (int) $_rtctest_ru['ru_stime.tv_usec'];
unset( $_rtctest_ru );

// =============================================================================
// MONITOR -- records metrics for requests tagged X-RTC-Test: 1
// =============================================================================

define( 'RTC_TEST_ENV_OPTION',        'rtc_test_env' );
define( 'RTC_TEST_CONCURRENT_OPTION', 'rtc_test_concurrent' );
define( 'RTC_TEST_DB_VERSION',        '3' );
define( 'RTC_TEST_REQUEST_HEADER',    'HTTP_X_RTC_TEST' );
define( 'RTC_TEST_SCENARIO_HEADER',   'HTTP_X_RTC_SCENARIO' );
define( 'RTC_TEST_APPROACH_HEADER',   'HTTP_X_RTC_APPROACH' );

// -------------------------------------------------------------------------
// Monitor: table helpers
// -------------------------------------------------------------------------

function rtctest_log_table() {
	global $wpdb;
	return $wpdb->prefix . 'rtctest_log';
}

function rtctest_ensure_table() {
	global $wpdb;
	$table = rtctest_log_table();

	// Fast path: version option matches AND the table physically exists with the
	// correct schema.  We spot-check the 'approach' column (added in version 3)
	// to catch tables left behind by an older version of this plugin.
	if ( get_option( 'rtctest_db_version' ) === RTC_TEST_DB_VERSION ) {
		$col = $wpdb->get_var( "SHOW COLUMNS FROM `{$table}` LIKE 'approach'" ); // phpcs:ignore
		if ( null !== $col ) {
			return; // Table exists and has the current schema.
		}
	}

	// Schema is missing or out of date.  Drop and recreate so the schema is
	// always correct.  This table holds only test measurements — correctness of
	// the schema matters more than preserving rows from an incompatible version.
	// phpcs:ignore WordPress.DB.DirectDatabaseQuery.SchemaChange
	$wpdb->query( "DROP TABLE IF EXISTS `{$table}`" ); // phpcs:ignore
	delete_option( 'rtctest_db_version' );

	$charset_collate = $wpdb->get_charset_collate();

	// Use a direct CREATE TABLE query instead of dbDelta() to avoid dbDelta()'s
	// strict SQL-formatting requirements, which can cause silent failures.
	// phpcs:ignore WordPress.DB.DirectDatabaseQuery.SchemaChange
	$wpdb->query(
		// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
		"CREATE TABLE `{$table}` (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			ts int(11) NOT NULL DEFAULT 0,
			approach varchar(60) NOT NULL DEFAULT '',
			scenario varchar(100) NOT NULL DEFAULT 'unknown',
			ms float NOT NULL DEFAULT 0,
			total_ms float NOT NULL DEFAULT 0,
			cpu_ms float NOT NULL DEFAULT 0,
			total_cpu_ms float NOT NULL DEFAULT 0,
			db_queries int(11) NOT NULL DEFAULT 0,
			db_time_ms float NOT NULL DEFAULT 0,
			memory_delta bigint(20) NOT NULL DEFAULT 0,
			peak_memory bigint(20) NOT NULL DEFAULT 0,
			status int(11) NOT NULL DEFAULT 200,
			rooms int(11) NOT NULL DEFAULT 0,
			updates_in int(11) NOT NULL DEFAULT 0,
			updates_out int(11) NOT NULL DEFAULT 0,
			response_bytes int(11) NOT NULL DEFAULT 0,
			awareness_count int(11) NOT NULL DEFAULT 0,
			should_compact tinyint(1) NOT NULL DEFAULT 0,
			total_updates int(11) NOT NULL DEFAULT 0,
			concurrent int(11) NOT NULL DEFAULT 0,
			PRIMARY KEY (id),
			KEY approach_scenario (approach, scenario),
			KEY ts (ts)
		) {$charset_collate}"
	);

	// Only mark the version current if the table was actually created.
	if ( null !== $wpdb->get_var( "SHOW COLUMNS FROM `{$table}` LIKE 'approach'" ) ) { // phpcs:ignore
		update_option( 'rtctest_db_version', RTC_TEST_DB_VERSION, true );
	} else {
		error_log( '[rtctest] Failed to create table ' . $table . ': ' . $wpdb->last_error );
	}
}

function rtctest_drop_table() {
	global $wpdb;
	// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
	$wpdb->query( 'DROP TABLE IF EXISTS ' . rtctest_log_table() );
	delete_option( 'rtctest_db_version' );
}

rtctest_ensure_table();

// -------------------------------------------------------------------------
// Monitor: request lifecycle hooks
// -------------------------------------------------------------------------

add_filter( 'rest_pre_dispatch',  'rtctest_pre_dispatch',  10, 3 );
add_filter( 'rest_post_dispatch', 'rtctest_post_dispatch', 10, 3 );

function rtctest_pre_dispatch( $result, $server, $request ) {
	// Accept the tag from three sources, in order of reliability:
	//   1. HTTP header (blocked by some reverse proxies)
	//   2. PHP $_GET superglobal (never filtered by WordPress)
	//   3. WP_REST_Request::get_param() (goes through WP param processing)
	$tagged = isset( $_SERVER[ RTC_TEST_REQUEST_HEADER ] )
	       || '1' === ( $_GET['_rtctest'] ?? '' )
	       || '1' === (string) $request->get_param( '_rtctest' );
	if ( ! $tagged ) {
		return $result;
	}
	if ( false === strpos( $request->get_route(), '/wp-sync/' ) ) {
		return $result;
	}

	global $wpdb;

	$GLOBALS['rtctest_wall_start'] = microtime( true );

	// Atomic concurrency increment before the query baseline snapshot.
	$GLOBALS['rtctest_concurrent_at_start'] = rtctest_increment_concurrent();
	register_shutdown_function( 'rtctest_decrement_concurrent' );

	$GLOBALS['rtctest_queries_start'] = $wpdb->num_queries;
	$GLOBALS['rtctest_dbtime_start']  = rtctest_db_time_so_far();
	$GLOBALS['rtctest_memory_start']  = memory_get_usage( true );

	$ru = getrusage();
	$GLOBALS['rtctest_cpu_start'] = (int) $ru['ru_utime.tv_sec'] * 1000000 + (int) $ru['ru_utime.tv_usec']
	                              + (int) $ru['ru_stime.tv_sec'] * 1000000 + (int) $ru['ru_stime.tv_usec'];

	return $result;
}

function rtctest_post_dispatch( $response, $server, $request ) {
	if ( ! isset( $GLOBALS['rtctest_wall_start'] ) ) {
		return $response;
	}

	global $wpdb;

	$wall_ms      = round( ( microtime( true ) - $GLOBALS['rtctest_wall_start'] ) * 1000, 2 );
	$db_queries   = $wpdb->num_queries - $GLOBALS['rtctest_queries_start'];
	$db_time_ms   = round( ( rtctest_db_time_so_far() - $GLOBALS['rtctest_dbtime_start'] ) * 1000, 2 );
	$memory_delta = memory_get_usage( true ) - $GLOBALS['rtctest_memory_start'];

	$ru      = getrusage();
	$cpu_end = (int) $ru['ru_utime.tv_sec'] * 1000000 + (int) $ru['ru_utime.tv_usec']
	         + (int) $ru['ru_stime.tv_sec'] * 1000000 + (int) $ru['ru_stime.tv_usec'];
	$cpu_ms       = round( ( $cpu_end - $GLOBALS['rtctest_cpu_start'] ) / 1000, 2 );
	$total_cpu_ms = isset( $GLOBALS['rtctest_boot_cpu'] )
		? round( ( $cpu_end - $GLOBALS['rtctest_boot_cpu'] ) / 1000, 2 )
		: 0.0;

	$request_start = isset( $_SERVER['REQUEST_TIME_FLOAT'] ) ? (float) $_SERVER['REQUEST_TIME_FLOAT'] : 0.0;
	$total_ms      = $request_start > 0
		? round( ( microtime( true ) - $request_start ) * 1000, 2 )
		: 0.0;

	$scenario = isset( $_SERVER[ RTC_TEST_SCENARIO_HEADER ] )
		? sanitize_text_field( wp_unslash( $_SERVER[ RTC_TEST_SCENARIO_HEADER ] ) )
		: sanitize_text_field( (string) ( $request->get_param( '_rtcscenario' ) ?? 'unknown' ) );

	$approach = isset( $_SERVER[ RTC_TEST_APPROACH_HEADER ] )
		? sanitize_text_field( wp_unslash( $_SERVER[ RTC_TEST_APPROACH_HEADER ] ) )
		: sanitize_text_field( (string) ( $request->get_param( '_rtcapproach' ) ?? '' ) );

	$data      = $response->get_data();
	$rooms_in  = $request->get_param( 'rooms' ) ?? array();
	$rooms_out = isset( $data['rooms'] ) && is_array( $data['rooms'] ) ? $data['rooms'] : array();

	$updates_in = 0;
	foreach ( $rooms_in as $r ) {
		$updates_in += isset( $r['updates'] ) ? count( $r['updates'] ) : 0;
	}

	$updates_out = 0;
	foreach ( $rooms_out as $r ) {
		$updates_out += isset( $r['updates'] ) ? count( $r['updates'] ) : 0;
	}

	$first_room_out  = ! empty( $rooms_out ) ? $rooms_out[0] : array();
	$awareness_count = isset( $first_room_out['awareness'] ) && is_array( $first_room_out['awareness'] )
		? count( $first_room_out['awareness'] )
		: 0;
	$should_compact = isset( $first_room_out['should_compact'] ) ? (bool) $first_room_out['should_compact'] : false;
	$total_updates  = isset( $first_room_out['total_updates'] ) ? (int) $first_room_out['total_updates'] : 0;
	$response_bytes = strlen( wp_json_encode( $data ) );

	// Build the row data and format array once so we can retry if the first
	// insert fails (e.g. because the table was dropped while the db_version
	// option remained set, causing rtctest_ensure_table() to skip creation).
	$row_data = array(
		'ts'              => time(),
		'approach'        => $approach,
		'scenario'        => $scenario,
		'ms'              => $wall_ms,
		'total_ms'        => $total_ms,
		'cpu_ms'          => $cpu_ms,
		'total_cpu_ms'    => $total_cpu_ms,
		'db_queries'      => $db_queries,
		'db_time_ms'      => $db_time_ms,
		'memory_delta'    => $memory_delta,
		'peak_memory'     => memory_get_peak_usage( true ),
		'status'          => $response->get_status(),
		'rooms'           => count( $rooms_in ),
		'updates_in'      => $updates_in,
		'updates_out'     => $updates_out,
		'response_bytes'  => $response_bytes,
		'awareness_count' => $awareness_count,
		'should_compact'  => $should_compact ? 1 : 0,
		'total_updates'   => $total_updates,
		'concurrent'      => $GLOBALS['rtctest_concurrent_at_start'],
	);
	$row_fmt = array(
		'%d', '%s', '%s', '%f', '%f', '%f', '%f', '%d', '%f',
		'%d', '%d', '%d', '%d', '%d', '%d', '%d', '%d', '%d', '%d', '%d',
	);

	$inserted  = $wpdb->insert( rtctest_log_table(), $row_data, $row_fmt );
	$db_error  = $wpdb->last_error;

	if ( false === $inserted ) {
		// Insert failed — most likely the table was dropped while the
		// rtctest_db_version option remained set (so ensure_table was a no-op).
		// Reset the version flag, recreate the table, and retry once.
		error_log( '[rtctest] insert failed: ' . $db_error . ' — recreating table.' );
		delete_option( 'rtctest_db_version' );
		rtctest_ensure_table();
		$inserted = $wpdb->insert( rtctest_log_table(), $row_data, $row_fmt );
		$db_error = $wpdb->last_error;
		if ( false === $inserted ) {
			error_log( '[rtctest] insert retry failed: ' . $db_error );
		}
	}

	// Diagnostic response headers — visible in curl -D output for debugging:
	//   X-RTC-Test-Active: 1  → hook executed (always set when we reach here)
	//   X-RTC-DB-Insert:   1  → row was written; 0 → insert failed
	//   X-RTC-DB-Error:    …  → MySQL error on insert failure (URL-encoded)
	if ( $response instanceof WP_REST_Response ) {
		$response->header( 'X-RTC-Test-Active', '1' );
		$response->header( 'X-RTC-DB-Insert', false !== $inserted ? '1' : '0' );
		if ( false === $inserted && '' !== $db_error ) {
			$response->header( 'X-RTC-DB-Error', rawurlencode( substr( $db_error, 0, 300 ) ) );
		}
	}

	unset(
		$GLOBALS['rtctest_wall_start'],
		$GLOBALS['rtctest_queries_start'],
		$GLOBALS['rtctest_dbtime_start'],
		$GLOBALS['rtctest_memory_start'],
		$GLOBALS['rtctest_cpu_start'],
		$GLOBALS['rtctest_concurrent_at_start']
	);

	return $response;
}

// -------------------------------------------------------------------------
// Monitor: concurrency counter helpers
// -------------------------------------------------------------------------

function rtctest_db_time_so_far() {
	global $wpdb;
	if ( ! defined( 'SAVEQUERIES' ) || ! SAVEQUERIES || ! is_array( $wpdb->queries ) ) {
		return 0.0;
	}
	$total = 0.0;
	foreach ( $wpdb->queries as $q ) {
		$total += isset( $q[1] ) ? (float) $q[1] : 0.0;
	}
	return $total;
}

function rtctest_increment_concurrent() {
	global $wpdb;
	$wpdb->query(
		$wpdb->prepare(
			"INSERT INTO {$wpdb->options} (option_name, option_value, autoload)
			 VALUES (%s, '1', 'no')
			 ON DUPLICATE KEY UPDATE option_value = CAST(option_value AS UNSIGNED) + 1",
			RTC_TEST_CONCURRENT_OPTION
		)
	);
	return (int) $wpdb->get_var(
		$wpdb->prepare(
			"SELECT option_value FROM {$wpdb->options} WHERE option_name = %s",
			RTC_TEST_CONCURRENT_OPTION
		)
	);
}

function rtctest_decrement_concurrent() {
	global $wpdb;
	$wpdb->query(
		$wpdb->prepare(
			"UPDATE {$wpdb->options}
			 SET option_value = GREATEST(CAST(option_value AS UNSIGNED), 1) - 1
			 WHERE option_name = %s",
			RTC_TEST_CONCURRENT_OPTION
		)
	);
}

// -------------------------------------------------------------------------
// Monitor: REST endpoints (rtc-test/v1)
// -------------------------------------------------------------------------

add_action( 'rest_api_init', 'rtctest_register_routes' );

function rtctest_register_routes() {
	$cap_check = static function() {
		return current_user_can( 'edit_posts' );
	};

	register_rest_route(
		'rtc-test/v1',
		'/log',
		array(
			array(
				'methods'             => WP_REST_Server::READABLE,
				'callback'            => static function() {
					global $wpdb;
					// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
					$rows = $wpdb->get_results(
						'SELECT * FROM ' . rtctest_log_table() . ' ORDER BY id ASC',
						ARRAY_A
					);
					foreach ( $rows as &$row ) {
						$row['id']              = (int) $row['id'];
						$row['ts']              = (int) $row['ts'];
						$row['approach']        = (string) $row['approach'];
						$row['ms']              = (float) $row['ms'];
						$row['total_ms']        = (float) $row['total_ms'];
						$row['cpu_ms']          = (float) $row['cpu_ms'];
						$row['total_cpu_ms']    = (float) $row['total_cpu_ms'];
						$row['db_queries']      = (int) $row['db_queries'];
						$row['db_time_ms']      = (float) $row['db_time_ms'];
						$row['memory_delta']    = (int) $row['memory_delta'];
						$row['peak_memory']     = (int) $row['peak_memory'];
						$row['status']          = (int) $row['status'];
						$row['rooms']           = (int) $row['rooms'];
						$row['updates_in']      = (int) $row['updates_in'];
						$row['updates_out']     = (int) $row['updates_out'];
						$row['response_bytes']  = (int) $row['response_bytes'];
						$row['awareness_count'] = (int) $row['awareness_count'];
						$row['should_compact']  = (bool) $row['should_compact'];
						$row['total_updates']   = (int) $row['total_updates'];
						$row['concurrent']      = (int) $row['concurrent'];
					}
					unset( $row );
					return rest_ensure_response( $rows );
				},
				'permission_callback' => $cap_check,
			),
			array(
				'methods'             => WP_REST_Server::DELETABLE,
				'callback'            => static function() {
					global $wpdb;
					// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
					$wpdb->query( 'DELETE FROM ' . rtctest_log_table() );
					return rest_ensure_response( array( 'cleared' => true ) );
				},
				'permission_callback' => $cap_check,
			),
		)
	);

	register_rest_route(
		'rtc-test/v1',
		'/table',
		array(
			'methods'             => WP_REST_Server::DELETABLE,
			'callback'            => static function() {
				rtctest_drop_table();
				return rest_ensure_response( array( 'dropped' => true ) );
			},
			'permission_callback' => $cap_check,
		)
	);

	register_rest_route(
		'rtc-test/v1',
		'/env',
		array(
			'methods'             => WP_REST_Server::READABLE,
			'callback'            => 'rtctest_get_env',
			'permission_callback' => $cap_check,
		)
	);

	register_rest_route(
		'rtc-test/v1',
		'/submit',
		array(
			'methods'             => WP_REST_Server::CREATABLE,
			'callback'            => 'rtctest_rest_submit',
			'permission_callback' => $cap_check,
			'args'                => array(
				'reporter_url'     => array(
					'required'          => true,
					'type'              => 'string',
					'sanitize_callback' => 'esc_url_raw',
				),
				'api_key'          => array(
					'required'          => true,
					'type'              => 'string',
					'description'       => 'Reporter credentials in username:password format (DOTORG_REPORT_API_KEY).',
					'sanitize_callback' => 'sanitize_text_field',
				),
				'environment_name' => array(
					'required'          => false,
					'type'              => 'string',
					'sanitize_callback' => 'sanitize_text_field',
				),
			),
		)
	);
}

function rtctest_detect_object_cache_type() {
	global $wp_object_cache;

	if ( ! wp_using_ext_object_cache() ) {
		return 'default'; // WP's built-in non-persistent in-memory cache.
	}

	// Popular Redis drop-ins set one of these constants.
	if ( defined( 'WP_REDIS_VERSION' ) ) {
		return 'redis'; // Redis Object Cache plugin (Till Krüss).
	}
	if ( defined( 'WP_REDIS_OBJECT_CACHE' ) ) {
		return 'redis'; // WP Redis (Pantheon / Human Made).
	}

	// Memcached drop-in (bundled with WordPress.com / Automattic).
	if ( defined( 'WP_CACHE_KEY_SALT' ) && class_exists( 'Memcached' ) ) {
		return 'memcached';
	}
	if ( class_exists( 'Memcache' ) ) {
		return 'memcache';
	}

	// Fall back to the actual class name — captures everything else.
	// Note: some drop-ins reuse the class name WP_Object_Cache even for
	// Redis/Memcached backends, which is why the constant checks come first.
	if ( isset( $wp_object_cache ) && is_object( $wp_object_cache ) ) {
		return 'ext:' . get_class( $wp_object_cache );
	}

	return 'ext:unknown';
}

function rtctest_get_env() {
	global $wpdb;

	if ( ! function_exists( 'get_plugins' ) ) {
		require_once ABSPATH . 'wp-admin/includes/plugin.php';
	}
	$gutenberg_file    = 'gutenberg/gutenberg.php';
	$all_plugins       = get_plugins();
	$gutenberg_data    = $all_plugins[ $gutenberg_file ] ?? null;
	$gutenberg_version = $gutenberg_data ? $gutenberg_data['Version'] : 'not-found';
	$gutenberg_active  = is_plugin_active( $gutenberg_file );

	$compaction_threshold = class_exists( 'WP_HTTP_Polling_Sync_Server' )
		? WP_HTTP_Polling_Sync_Server::COMPACTION_THRESHOLD
		: null;
	$awareness_timeout_s = class_exists( 'WP_HTTP_Polling_Sync_Server' )
		? WP_HTTP_Polling_Sync_Server::AWARENESS_TIMEOUT
		: null;

	$env = array(
		'php_version'          => PHP_VERSION,
		'wp_version'           => get_bloginfo( 'version' ),
		'db_version'           => $wpdb->db_version(),
		'gutenberg_version'    => $gutenberg_version,
		'gutenberg_active'     => $gutenberg_active,
		'ext_object_cache'     => wp_using_ext_object_cache(),
		'object_cache_type'    => rtctest_detect_object_cache_type(),
		'savequeries'          => defined( 'SAVEQUERIES' ) && SAVEQUERIES,
		'compaction_threshold' => $compaction_threshold,
		'awareness_timeout_s'  => $awareness_timeout_s,
		'captured_at'          => time(),
	);

	update_option( RTC_TEST_ENV_OPTION, $env, false );

	return rest_ensure_response( $env );
}

function rtctest_rest_submit( WP_REST_Request $request ) {
	global $wpdb;

	$reporter_url     = $request->get_param( 'reporter_url' );
	$api_key          = $request->get_param( 'api_key' );    // username:password format
	$environment_name = $request->get_param( 'environment_name' ) ?: get_option( 'siteurl' );

	// Build environment snapshot.
	$env = rtctest_get_env()->get_data();

	// Fetch all log rows.
	// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
	$rows = $wpdb->get_results(
		'SELECT approach, scenario, ms, total_ms, cpu_ms, total_cpu_ms, db_queries, db_time_ms, peak_memory, concurrent'
		. ' FROM ' . rtctest_log_table(),
		ARRAY_A
	);

	if ( empty( $rows ) ) {
		return new WP_Error( 'no_data', 'No log entries to submit.', array( 'status' => 400 ) );
	}

	// Aggregate by approach × scenario.
	$agg = array();
	foreach ( $rows as $row ) {
		$approach = '' !== $row['approach'] ? $row['approach'] : 'untagged';
		$scenario = $row['scenario'];
		if ( ! isset( $agg[ $approach ][ $scenario ] ) ) {
			$agg[ $approach ][ $scenario ] = array(
				'n'                => 0,
				'ms_sum'           => 0.0,
				'ms_sq_sum'        => 0.0,
				'total_ms_sum'     => 0.0,
				'cpu_ms_sum'       => 0.0,
				'total_cpu_ms_sum' => 0.0,
				'db_queries_sum'   => 0.0,
				'db_time_ms_sum'   => 0.0,
				'peak_memory_sum'  => 0.0,
				'max_concurrent'   => 0,
			);
		}
		$s  = &$agg[ $approach ][ $scenario ];
		$ms = (float) $row['ms'];
		$s['n']++;
		$s['ms_sum']           += $ms;
		$s['ms_sq_sum']        += $ms * $ms;
		$s['total_ms_sum']     += (float) $row['total_ms'];
		$s['cpu_ms_sum']       += (float) $row['cpu_ms'];
		$s['total_cpu_ms_sum'] += (float) $row['total_cpu_ms'];
		$s['db_queries_sum']   += (float) $row['db_queries'];
		$s['db_time_ms_sum']   += (float) $row['db_time_ms'];
		$s['peak_memory_sum']  += (float) $row['peak_memory'];
		if ( (int) $row['concurrent'] > $s['max_concurrent'] ) {
			$s['max_concurrent'] = (int) $row['concurrent'];
		}
		unset( $s );
	}

	// Build results structure.
	$results = array();
	foreach ( $agg as $approach => $scenarios ) {
		$results[ $approach ] = array();
		foreach ( $scenarios as $scenario => $s ) {
			$n    = $s['n'];
			$mean = $s['ms_sum'] / $n;
			$var  = max( 0.0, ( $s['ms_sq_sum'] / $n ) - ( $mean * $mean ) );
			$results[ $approach ][ $scenario ] = array(
				'n'                 => $n,
				'mean_disp_ms'      => round( $mean, 2 ),
				'mean_total_ms'     => round( $s['total_ms_sum'] / $n, 2 ),
				'mean_cpu_ms'       => round( $s['cpu_ms_sum'] / $n, 2 ),
				'mean_total_cpu_ms' => round( $s['total_cpu_ms_sum'] / $n, 2 ),
				'stddev_disp_ms'    => round( sqrt( $var ), 2 ),
				'mean_db_queries'   => round( $s['db_queries_sum'] / $n, 1 ),
				'mean_db_time_ms'   => round( $s['db_time_ms_sum'] / $n, 2 ),
				'mean_mem_mb'       => round( $s['peak_memory_sum'] / $n / 1048576, 2 ),
				'max_concurrent'    => $s['max_concurrent'],
			);
		}
	}

	$response = wp_remote_post(
		$reporter_url,
		array(
			'headers' => array(
				'Content-Type'  => 'application/json',
				'Authorization' => 'Basic ' . base64_encode( $api_key ),
			),
			'body'    => wp_json_encode( array(
				'environment_name' => $environment_name,
				'env'              => $env,
				'results'          => $results,
			) ),
			'timeout' => 30,
		)
	);

	if ( is_wp_error( $response ) ) {
		return new WP_Error( 'submit_failed', $response->get_error_message(), array( 'status' => 502 ) );
	}

	$http_code = wp_remote_retrieve_response_code( $response );
	$body      = wp_remote_retrieve_body( $response );

	if ( $http_code < 200 || $http_code >= 300 ) {
		return new WP_Error(
			'reporter_error',
			sprintf( 'Reporter returned HTTP %d: %s', $http_code, $body ),
			array( 'status' => 502 )
		);
	}

	return rest_ensure_response( array(
		'submitted' => true,
		'http_code' => $http_code,
		'response'  => json_decode( $body, true ) ?? $body,
	) );
}

// -------------------------------------------------------------------------
// Monitor: AJAX nonce endpoint (cookie auth)
// -------------------------------------------------------------------------

add_action( 'wp_ajax_rtctest_nonce', 'rtctest_ajax_nonce' );

function rtctest_ajax_nonce() {
	if ( ! current_user_can( 'edit_posts' ) ) {
		wp_die( 'Forbidden', '', array( 'response' => 403 ) );
	}
	wp_send_json( array( 'nonce' => wp_create_nonce( 'wp_rest' ) ) );
}

// =============================================================================
// CAPTURE -- records real browser /wp-sync/ sessions as replay fixtures
// =============================================================================

define( 'RTCAP_DB_VERSION', '1' );

// -------------------------------------------------------------------------
// Capture: table helpers
// -------------------------------------------------------------------------

function rtcap_frames_table() {
	global $wpdb;
	return $wpdb->prefix . 'rtcap_frames';
}

function rtcap_ensure_table() {
	if ( get_option( 'rtcap_db_version' ) === RTCAP_DB_VERSION ) {
		return;
	}

	global $wpdb;
	$table           = rtcap_frames_table();
	$charset_collate = $wpdb->get_charset_collate();

	$sql = "CREATE TABLE IF NOT EXISTS {$table} (
  id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  session_id varchar(100) NOT NULL DEFAULT '',
  ts_us bigint(20) NOT NULL DEFAULT 0,
  elapsed_ms float NOT NULL DEFAULT 0,
  client_id bigint(20) NOT NULL DEFAULT 0,
  room varchar(200) NOT NULL DEFAULT '',
  request_body longtext NOT NULL,
  response_body longtext NOT NULL,
  PRIMARY KEY  (id),
  KEY session_id (session_id),
  KEY ts_us (ts_us)
) {$charset_collate};";

	require_once ABSPATH . 'wp-admin/includes/upgrade.php';
	dbDelta( $sql );
	update_option( 'rtcap_db_version', RTCAP_DB_VERSION, true );
}

function rtcap_drop_table() {
	global $wpdb;
	// phpcs:ignore WordPress.DB.PreparedSQL.NotPrepared
	$wpdb->query( 'DROP TABLE IF EXISTS ' . rtcap_frames_table() );
	delete_option( 'rtcap_db_version' );
	delete_option( 'rtcap_session' );
	delete_option( 'rtcap_started_us' );
	delete_option( 'rtcap_room_filter' );
}

rtcap_ensure_table();

// -------------------------------------------------------------------------
// Capture: session state helpers
// -------------------------------------------------------------------------

function rtcap_active_session() {
	return (string) get_option( 'rtcap_session', '' );
}

function rtcap_started_us() {
	return (int) get_option( 'rtcap_started_us', 0 );
}

function rtcap_room_filter() {
	return (string) get_option( 'rtcap_room_filter', '' );
}

// -------------------------------------------------------------------------
// Capture: request lifecycle hooks
// -------------------------------------------------------------------------

add_filter( 'rest_pre_dispatch',  'rtcap_pre_dispatch',  10, 3 );
add_filter( 'rest_post_dispatch', 'rtcap_post_dispatch', 10, 3 );

function rtcap_pre_dispatch( $result, $server, $request ) {
	if ( false === strpos( $request->get_route(), '/wp-sync/' ) ) {
		return $result;
	}

	$session = rtcap_active_session();
	if ( '' === $session ) {
		return $result;
	}

	$room_filter = rtcap_room_filter();
	if ( '' !== $room_filter ) {
		$rooms_param = $request->get_param( 'rooms' );
		if ( ! is_array( $rooms_param ) ) {
			return $result;
		}
		$matched = false;
		foreach ( $rooms_param as $r ) {
			if ( isset( $r['room'] ) && $r['room'] === $room_filter ) {
				$matched = true;
				break;
			}
		}
		if ( ! $matched ) {
			return $result;
		}
	}

	$rooms_param = $request->get_param( 'rooms' );
	$first_room  = is_array( $rooms_param ) && ! empty( $rooms_param ) ? $rooms_param[0] : array();

	$GLOBALS['rtcap_active_session']  = $session;
	$GLOBALS['rtcap_request_body']    = $request->get_body();
	$GLOBALS['rtcap_ts_us']           = (int) round( microtime( true ) * 1000000 );
	$GLOBALS['rtcap_session_started'] = rtcap_started_us();
	$GLOBALS['rtcap_client_id']       = isset( $first_room['client_id'] ) ? (int) $first_room['client_id'] : 0;
	$GLOBALS['rtcap_room']            = isset( $first_room['room'] )      ? (string) $first_room['room']    : '';

	return $result;
}

function rtcap_post_dispatch( $response, $server, $request ) {
	if ( ! isset( $GLOBALS['rtcap_active_session'] ) ) {
		return $response;
	}

	global $wpdb;

	$ts_us      = $GLOBALS['rtcap_ts_us'];
	$started    = $GLOBALS['rtcap_session_started'];
	$elapsed_ms = $started > 0 ? round( ( $ts_us - $started ) / 1000, 2 ) : 0.0;

	$wpdb->insert(
		rtcap_frames_table(),
		array(
			'session_id'    => $GLOBALS['rtcap_active_session'],
			'ts_us'         => $ts_us,
			'elapsed_ms'    => $elapsed_ms,
			'client_id'     => $GLOBALS['rtcap_client_id'],
			'room'          => $GLOBALS['rtcap_room'],
			'request_body'  => $GLOBALS['rtcap_request_body'],
			'response_body' => wp_json_encode( $response->get_data() ),
		),
		array( '%s', '%d', '%f', '%d', '%s', '%s', '%s' )
	);

	unset(
		$GLOBALS['rtcap_active_session'],
		$GLOBALS['rtcap_request_body'],
		$GLOBALS['rtcap_ts_us'],
		$GLOBALS['rtcap_session_started'],
		$GLOBALS['rtcap_client_id'],
		$GLOBALS['rtcap_room']
	);

	return $response;
}

// -------------------------------------------------------------------------
// Capture: REST endpoints (rtc-capture/v1)
// -------------------------------------------------------------------------

add_action( 'rest_api_init', 'rtcap_register_routes' );

function rtcap_register_routes() {
	$cap = static function() { return current_user_can( 'edit_posts' ); };

	register_rest_route( 'rtc-capture/v1', '/session/start', array(
		'methods'             => WP_REST_Server::CREATABLE,
		'callback'            => 'rtcap_rest_start',
		'permission_callback' => $cap,
	) );

	register_rest_route( 'rtc-capture/v1', '/session/stop', array(
		'methods'             => WP_REST_Server::CREATABLE,
		'callback'            => 'rtcap_rest_stop',
		'permission_callback' => $cap,
	) );

	register_rest_route( 'rtc-capture/v1', '/sessions', array(
		array(
			'methods'             => WP_REST_Server::READABLE,
			'callback'            => 'rtcap_rest_list',
			'permission_callback' => $cap,
		),
		array(
			'methods'             => WP_REST_Server::DELETABLE,
			'callback'            => static function() {
				rtcap_drop_table();
				return rest_ensure_response( array( 'dropped' => true ) );
			},
			'permission_callback' => $cap,
		),
	) );

	// /session/start and /session/stop are literal paths registered above
	// and match before this regex pattern.
	register_rest_route( 'rtc-capture/v1', '/session/(?P<id>[a-zA-Z0-9_-]+)', array(
		array(
			'methods'             => WP_REST_Server::READABLE,
			'callback'            => 'rtcap_rest_export',
			'permission_callback' => $cap,
		),
		array(
			'methods'             => WP_REST_Server::DELETABLE,
			'callback'            => 'rtcap_rest_delete',
			'permission_callback' => $cap,
		),
	) );
}

function rtcap_rest_start( WP_REST_Request $request ) {
	$session_id  = sanitize_text_field( (string) ( $request->get_param( 'session_id' )  ?? '' ) );
	$room_filter = sanitize_text_field( (string) ( $request->get_param( 'room_filter' ) ?? '' ) );

	if ( '' === $session_id ) {
		return new WP_Error( 'missing_session_id', 'session_id is required', array( 'status' => 400 ) );
	}

	$now_us = (int) round( microtime( true ) * 1000000 );
	update_option( 'rtcap_session',     $session_id,  true );
	update_option( 'rtcap_started_us',  $now_us,       true );
	update_option( 'rtcap_room_filter', $room_filter,  true );

	return rest_ensure_response( array(
		'started'     => true,
		'session_id'  => $session_id,
		'room_filter' => $room_filter,
		'started_us'  => $now_us,
	) );
}

function rtcap_rest_stop() {
	$session_id = rtcap_active_session();
	if ( '' === $session_id ) {
		return new WP_Error( 'no_active_session', 'No capture session is active', array( 'status' => 400 ) );
	}

	global $wpdb;
	$frames = (int) $wpdb->get_var( $wpdb->prepare(
		'SELECT COUNT(*) FROM ' . rtcap_frames_table() . ' WHERE session_id = %s',
		$session_id
	) );

	update_option( 'rtcap_session',     '', true );
	update_option( 'rtcap_room_filter', '', true );

	return rest_ensure_response( array(
		'stopped'    => true,
		'session_id' => $session_id,
		'frames'     => $frames,
	) );
}

function rtcap_rest_list() {
	global $wpdb;
	$table = rtcap_frames_table();

	$rows = $wpdb->get_results(
		"SELECT session_id, COUNT(*) AS frames,
		        MIN(ts_us) AS first_us, MAX(ts_us) AS last_us
		 FROM {$table} GROUP BY session_id ORDER BY first_us ASC",
		ARRAY_A
	);

	$current  = rtcap_active_session();
	$sessions = array();
	foreach ( $rows as $row ) {
		$sessions[] = array(
			'session_id'  => $row['session_id'],
			'frames'      => (int) $row['frames'],
			'first_us'    => (int) $row['first_us'],
			'last_us'     => (int) $row['last_us'],
			'duration_ms' => (int) round( ( (int) $row['last_us'] - (int) $row['first_us'] ) / 1000 ),
			'active'      => ( $row['session_id'] === $current ),
		);
	}

	return rest_ensure_response( $sessions );
}

function rtcap_rest_export( WP_REST_Request $request ) {
	$session_id = sanitize_text_field( $request->get_param( 'id' ) );

	global $wpdb;
	$rows = $wpdb->get_results( $wpdb->prepare(
		'SELECT * FROM ' . rtcap_frames_table() . ' WHERE session_id = %s ORDER BY id ASC',
		$session_id
	), ARRAY_A );

	if ( empty( $rows ) ) {
		return new WP_Error( 'not_found', 'Session not found or has no frames', array( 'status' => 404 ) );
	}

	$frames = array();
	$n      = 1;
	foreach ( $rows as $row ) {
		$frames[] = array(
			'n'          => $n,
			'elapsed_ms' => (float) $row['elapsed_ms'],
			'client_id'  => (int) $row['client_id'],
			'room'       => $row['room'],
			'request'    => json_decode( $row['request_body'],  true ) ?? array(),
			'response'   => json_decode( $row['response_body'], true ) ?? array(),
		);
		$n++;
	}

	return rest_ensure_response( array(
		'session_id'  => $session_id,
		'frame_count' => count( $frames ),
		'frames'      => $frames,
	) );
}

function rtcap_rest_delete( WP_REST_Request $request ) {
	$session_id = sanitize_text_field( $request->get_param( 'id' ) );

	global $wpdb;
	$deleted = $wpdb->delete( rtcap_frames_table(), array( 'session_id' => $session_id ), array( '%s' ) );

	return rest_ensure_response( array(
		'deleted'    => true,
		'session_id' => $session_id,
		'rows'       => (int) $deleted,
	) );
}

// -------------------------------------------------------------------------
// Capture: WP-CLI commands
// -------------------------------------------------------------------------

if ( defined( 'WP_CLI' ) && WP_CLI ) {

	/**
	 * Manages RTC capture sessions.
	 *
	 * ## EXAMPLES
	 *
	 *   wp rtc-capture start session-typing-a --room=postType/post:42
	 *   wp rtc-capture stop
	 *   wp rtc-capture list
	 *   wp rtc-capture export session-typing-a
	 *   wp rtc-capture drop session-typing-a
	 *   wp rtc-capture drop --all
	 */
	class RTC_Capture_CLI extends WP_CLI_Command {

		/**
		 * Start a capture session.
		 *
		 * ## OPTIONS
		 *
		 * <session-id>
		 * : Unique name for this session (alphanumeric, hyphens, underscores).
		 *
		 * [--room=<room>]
		 * : Room identifier to filter on, e.g. postType/post:42. Omit to capture all rooms.
		 *
		 * @param array $args
		 * @param array $assoc_args
		 */
		public function start( $args, $assoc_args ) {
			if ( empty( $args[0] ) ) {
				WP_CLI::error( 'Session ID is required.' );
			}
			$session_id  = sanitize_text_field( $args[0] );
			$room_filter = isset( $assoc_args['room'] ) ? sanitize_text_field( $assoc_args['room'] ) : '';

			$now_us = (int) round( microtime( true ) * 1000000 );
			update_option( 'rtcap_session',     $session_id,  true );
			update_option( 'rtcap_started_us',  $now_us,       true );
			update_option( 'rtcap_room_filter', $room_filter,  true );

			WP_CLI::success( sprintf(
				'Capture started: %s%s',
				$session_id,
				$room_filter ? "  (room: {$room_filter})" : '  (all rooms)'
			) );
		}

		/** Stop the current capture session. */
		public function stop() {
			$session_id = rtcap_active_session();
			if ( '' === $session_id ) {
				WP_CLI::error( 'No active capture session.' );
			}

			global $wpdb;
			$frames = (int) $wpdb->get_var( $wpdb->prepare(
				'SELECT COUNT(*) FROM ' . rtcap_frames_table() . ' WHERE session_id = %s',
				$session_id
			) );

			update_option( 'rtcap_session',     '', true );
			update_option( 'rtcap_room_filter', '', true );

			WP_CLI::success( sprintf( 'Stopped: %s  (%d frames)', $session_id, $frames ) );
		}

		/** List all captured sessions. */
		public function list() {
			global $wpdb;
			$table = rtcap_frames_table();
			$rows  = $wpdb->get_results(
				"SELECT session_id, COUNT(*) AS frames,
				        MIN(ts_us) AS first_us, MAX(ts_us) AS last_us
				 FROM {$table} GROUP BY session_id ORDER BY first_us ASC",
				ARRAY_A
			);

			if ( empty( $rows ) ) {
				WP_CLI::log( 'No sessions.' );
				return;
			}

			$current = rtcap_active_session();
			$items   = array();
			foreach ( $rows as $row ) {
				$items[] = array(
					'session_id'  => $row['session_id'] . ( $row['session_id'] === $current ? ' *' : '' ),
					'frames'      => $row['frames'],
					'started'     => gmdate( 'H:i:s', (int) ( (int) $row['first_us'] / 1000000 ) ),
					'duration_ms' => (int) round( ( (int) $row['last_us'] - (int) $row['first_us'] ) / 1000 ),
				);
			}

			WP_CLI\Utils\format_items( 'table', $items, array( 'session_id', 'frames', 'started', 'duration_ms' ) );
		}

		/**
		 * Print the REST export URL for a session.
		 *
		 * @param array $args
		 */
		public function export( $args ) {
			if ( empty( $args[0] ) ) {
				WP_CLI::error( 'Session ID is required.' );
			}
			$session_id = sanitize_text_field( $args[0] );
			WP_CLI::log( rest_url( 'rtc-capture/v1/session/' . rawurlencode( $session_id ) ) );
		}

		/**
		 * Delete a session or drop the entire table.
		 *
		 * ## OPTIONS
		 *
		 * [<session-id>]
		 * : Session to delete. Omit and use --all to drop the entire table.
		 *
		 * [--all]
		 * : Drop the entire frames table.
		 *
		 * @param array $args
		 * @param array $assoc_args
		 */
		public function drop( $args, $assoc_args ) {
			if ( ! empty( $assoc_args['all'] ) ) {
				rtcap_drop_table();
				WP_CLI::success( 'Table dropped.' );
				return;
			}

			if ( empty( $args[0] ) ) {
				WP_CLI::error( 'Provide a session ID or --all.' );
			}

			$session_id = sanitize_text_field( $args[0] );
			global $wpdb;
			$deleted = $wpdb->delete( rtcap_frames_table(), array( 'session_id' => $session_id ), array( '%s' ) );
			WP_CLI::success( sprintf( 'Deleted %d rows for session: %s', (int) $deleted, $session_id ) );
		}
	}

	WP_CLI::add_command( 'rtc-capture', 'RTC_Capture_CLI' );
}
