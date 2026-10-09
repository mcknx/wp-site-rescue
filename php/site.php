<?php
// wp eval-file /php/site.php — clinic settings around the home page: booking form, menu, theme CSS, footer, news posts, permalinks. Idempotent.

// Contact Form 7 booking form.
$forms = get_posts(['post_type' => 'wpcf7_contact_form', 'numberposts' => -1]);
foreach ($forms as $f) if ($f->post_title !== 'Book an appointment') wp_delete_post($f->ID, true);
$existing = get_posts(['post_type' => 'wpcf7_contact_form', 'numberposts' => 1, 'title' => 'Book an appointment']);
$cf = $existing ? WPCF7_ContactForm::get_instance($existing[0]->ID) : WPCF7_ContactForm::get_template(['title' => 'Book an appointment']);
$cf->set_properties(['form' => implode("\n", [
	'<label>Your name [text* your-name autocomplete:name]</label>',
	'<label>Email [email* your-email autocomplete:email]</label>',
	'<label>Mobile number [tel your-phone]</label>',
	'<label>What do you need? [textarea your-message 40x3]</label>',
	'[submit "Request appointment"]',
])]);
$cf->save();

// Header menu (anchor links on the one-page home).
$menu = wp_get_nav_menu_object('Main') ?: get_term(wp_create_nav_menu('Main'), 'nav_menu');
foreach (wp_get_nav_menu_items($menu->term_id) ?: [] as $item) wp_delete_post($item->ID, true);
foreach (['Services' => '#services', 'About' => '#about', 'Team' => '#team', 'Reviews' => '#reviews', 'Book a visit' => '#contact'] as $t => $u)
	wp_update_nav_menu_item($menu->term_id, 0, ['menu-item-title' => $t, 'menu-item-url' => home_url("/$u"), 'menu-item-status' => 'publish', 'menu-item-type' => 'custom']);
set_theme_mod('nav_menu_locations', ['primary' => $menu->term_id, 'mobile_menu' => $menu->term_id]);

// Small theme CSS (Customizer → Additional CSS), as a site owner would add it.
wp_update_custom_css_post(<<<'CSS'
.bd-avatar{width:120px;height:120px;margin:0 auto;border-radius:50%;display:flex;align-items:center;justify-content:center;background:#1B998B;color:#fff;font:700 38px/1 Poppins,sans-serif}
.bd-hero .elementor-widget-button{width:auto;margin-right:12px}
.bd-gallery .gallery-item img{width:100%;height:auto;aspect-ratio:4/3;object-fit:cover;border-radius:10px}
.bd-form .wpcf7 label{display:block;color:#fff;font-family:"Open Sans",sans-serif;margin-bottom:14px}
.bd-form .wpcf7 input:not([type=submit]),.bd-form .wpcf7 textarea{width:100%;margin-top:6px;padding:12px 14px;border:0;border-radius:8px;background:#fff}
.bd-form .wpcf7 textarea{height:110px}
.bd-slots{color:#E8F1F5;font-family:"Open Sans",sans-serif;margin-bottom:18px}
.bd-form .wpcf7-submit{background:#1B998B;color:#fff;border:0;border-radius:30px;padding:14px 30px;font-weight:600}
CSS);

// Footer line (Astra → Footer Builder → Copyright).
$astra = get_option('astra-settings', []);
$astra['footer-copyright-editor'] = 'Copyright &copy; [current_year] Bayview Dental · J.P. Laurel Avenue, Davao City · demo site';
update_option('astra-settings', $astra);

// Two clinic news posts; WordPress's samples go.
foreach (['hello-world' => 'post', 'sample-page' => 'page', 'privacy-policy' => 'page'] as $slug => $type)
	if ($p = get_page_by_path($slug, OBJECT, $type)) wp_delete_post($p->ID, true);
$news = [
	'saturday-hours' => ['We are now open on Saturdays', '<!-- wp:paragraph --><p>From October, Bayview Dental is open Monday to Saturday, 9am to 6pm. Saturday slots fill up first, so book a few days ahead.</p><!-- /wp:paragraph -->'],
	'first-visit' => ['What to expect at your first visit', '<!-- wp:paragraph --><p>Your first visit is a full check-up: we look at every tooth, take X-rays if you need them, and tell you the price of any treatment before we start.</p><!-- /wp:paragraph -->'],
];
foreach ($news as $slug => [$title, $content]) {
	$p = get_page_by_path($slug, OBJECT, 'post');
	wp_insert_post(['ID' => $p ? $p->ID : 0, 'post_type' => 'post', 'post_status' => 'publish', 'post_name' => $slug, 'post_title' => $title, 'post_content' => $content, 'post_author' => 1]);
}

update_option('blogdescription', 'Family dental clinic in Davao City (demo)');
update_option('permalink_structure', '/%postname%/');
add_filter('got_rewrite', '__return_true');
flush_rewrite_rules(true);
WP_CLI::success('site settings done');
