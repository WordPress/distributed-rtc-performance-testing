<?php
/**
 * CLI helpers for rtc-test.sh — no WordPress required.
 *
 * Usage:
 *   php rtc-helpers.php capture-sanitize <fixture.json>
 *   php rtc-helpers.php replay-extract   <fixture.json>
 */

$command = $argv[1] ?? '';
$file    = $argv[2] ?? '';

// Use realpath() + is_file() rather than file_exists() — the latter resolves
// PHP stream wrappers (php://filter, phar://) which would bypass this guard.
$real = '' !== $file ? realpath( $file ) : false;
if ( false === $real || ! is_file( $real ) ) {
	fwrite( STDERR, "Usage: php rtc-helpers.php <capture-sanitize|replay-extract> <fixture.json>\n" );
	exit( 1 );
}
$file = $real;

switch ( $command ) {
	case 'capture-sanitize':
		rtctest_capture_sanitize( $file );
		break;
	case 'replay-extract':
		rtctest_replay_extract( $file );
		break;
	default:
		fwrite( STDERR, "Unknown command: {$command}\n" );
		exit( 1 );
}

// -----------------------------------------------------------------------------

function rtctest_capture_sanitize( string $file ) {
	$data = json_decode( file_get_contents( $file ), true );
	if ( null === $data ) {
		fwrite( STDERR, 'capture-sanitize: ' . json_last_error_msg() . "\n" );
		exit( 1 );
	}
	$frames_in  = $data['frames'] ?? [];
	$frames_out = [];

	foreach ( $frames_in as $frame ) {
		$rooms     = $frame['request']['rooms'] ?? [];
		$post_room = null;
		foreach ( $rooms as $r ) {
			if ( strpos( $r['room'] ?? '', 'postType/post:' ) === 0 ) {
				$post_room = $r;
				break;
			}
		}
		if ( null === $post_room ) {
			continue;
		}
		$frames_out[] = [
			'n'          => $frame['n'] ?? count( $frames_out ) + 1,
			'elapsed_ms' => $frame['elapsed_ms'] ?? 0,
			'client_id'  => $frame['client_id'] ?? 0,
			'request'    => [ 'rooms' => [ [
				'room'      => 'postType/post:0',
				'client_id' => $post_room['client_id'] ?? ( $frame['client_id'] ?? 0 ),
				'awareness' => new stdClass(),
				'after'     => 0,
				'updates'   => $post_room['updates'] ?? [],
			] ] ],
		];
	}

	$out = [
		'session_id'  => $data['session_id'] ?? '',
		'frame_count' => count( $frames_out ),
		'frames'      => $frames_out,
	];

	echo json_encode( $out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ) . "\n";
}

function rtctest_replay_extract( string $file ) {
	$data = json_decode( file_get_contents( $file ), true );
	if ( null === $data ) {
		fwrite( STDERR, 'replay-extract: ' . json_last_error_msg() . "\n" );
		exit( 1 );
	}

	foreach ( $data['frames'] ?? [] as $frame ) {
		$elapsed_ms = (int) ( $frame['elapsed_ms'] ?? 0 );
		$client_id  = (int) ( $frame['client_id'] ?? 0 );
		$rooms      = $frame['request']['rooms'] ?? [];
		foreach ( $rooms as $r ) {
			if ( strpos( $r['room'] ?? '', 'postType/post:' ) === 0 ) {
				$updates     = $r['updates'] ?? [];
				$updates_str = implode( ',', array_map( function ( $u ) {
					return json_encode( $u, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE );
				}, $updates ) );
				echo $elapsed_ms . "\t" . $client_id . "\t" . $updates_str . "\n";
				break;
			}
		}
	}
}
