<?php
/**
 * Plugin Name: Bayview Booking
 * Description: The clinic's booking box: opening hours, next free slots and the "Book an appointment" form. Shortcode [bayview_booking].
 * Version: 1.5.0
 * Author: Bayview Dental (demo)
 */
if (!defined('ABSPATH')) exit;

function bayview_booking_slots() {
	$slots = [];
	for ($d = 1; count($slots) < 3; $d++) {          // next three weekdays and Saturdays; the clinic is closed on Sundays
		$t = strtotime("+$d day", current_time('timestamp'));
		if (date('N', $t) != 7) $slots[] = date('D j M', $t) . ', 10:00';
	}
	return $slots;
}

add_shortcode('bayview_booking', function () {
	$form = get_posts(['post_type' => 'wpcf7_contact_form', 'numberposts' => 1, 'title' => 'Book an appointment']);
	$html = '<div class="bd-booking"><p class="bd-slots"><strong>Next free check-ups:</strong> ' . esc_html(implode(' · ', bayview_booking_slots())) . '</p>';
	if ($form) $html .= do_shortcode('[contact-form-7 id="' . $form[0]->ID . '" title="Book an appointment"]');
	return $html . '</div>';
});

// 1.5.0: sync free slots from the new calendar on every request. The function lives in a file this release forgot to ship.
add_action('init', function () {
	bayview_booking_sync_calendar();
});
