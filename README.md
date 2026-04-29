# Distributed Real-time Collaboration Performance Tests

This repository is a set of scripts intended to run within a hosting environment to provide performance data for the new real-time collaboration feature shipping in WordPress 7.0.

This data will help Core contributors determine which architectural approach is the most sound and safest at scale.

## Requirements

The following tools are **required** to run this test script:

- bash
- cURL
- WP-CLI (configured to run at `wp`)
- patch


### Optional

The following libraries are recommended but optional:

- openssl

## Setup Instructions

First, of you are a hosting provider looking to run these tests, thank you!

Here are the list of steps to follow:

### Clone the repository

This repository can be cloned anywhere on a server.

```bash
git clone https://github.com/WordPress/distributed-rtc-performance-testing.git <path>
```

### Configure the test runner.

While the runner is designed to run without any file modifications, it does require some configuration through a handful of environment variables (see [.env.example](.env.example) for an annotated overview) which are documentated below.

Run the following command to create an `.env` file from the example:

```bash
cp .env.example .env
```

You can then edit the `.env` file using the editor of your choice to adjust the configuration.

The following variables **must** be configured:

- `WP_PATH`: This should be the absolute path of root directory for the test WordPress installation.
- `ENVIRONMENT_NAME`: A descriptive label of the environment running the tests. For example, "Performance Shared" or "Managed eCommerce". This will help the Core contributors analyzing the data understand the type of hosting.
- `REPORTER_API_KEY`: The credentials of the reporting user the format of `username:appl icat ion- pass word`.

#### Notes
- Hosts participating in the [PHPUnit Hosting Tests](https://make.wordpress.org/hosting/test-results/) can reuse the same credentials for this test runner.
- If you do not have a test bot and need to set one up, see the [Submitting Test Results section below](#submitting-test-results).

**WARNING:** The test runner will erase the contents of the configured site. Do not configure the test runner to use a production site, or any site that cannot be wiped clean.

### Run the Tests

```bash
bash run.sh
```

This will set up the environment, run the tests, and attempt to submit the results to WordPress.org.

---

## Submitting Test Results

A WordPress.org bot account is required to submit test results.

If you have participated in the [PHPUnit Distributed Hosting Tests](https://make.wordpress.org/hosting/test-results/) before, please reuse the same bot account and create a new application password. Here are the steps from the :

Otherwise, please follow these steps below:

1. Create a bot WordPress.org account. If your company is Wonderful Hosting, Inc., this bot account username might be `wonderfulbot`. Make sure to set its email address to something monitored by a human. Please add a Gravatar/logo and URL that clearly represents your company to the profile as well.
2. [Create a new issue](https://github.com/WordPress/distributed-rtc-performance-testing/issues/new?title=Promote+%60DOTORG_BOT_NAME%60+to+Test+Reporter&body=COMPANY_NAME+would+like+to+submit+test+results+from+the+distributed+real-time+collaboration+test+suite.%0A%0A*+Username%3A+%60DOTORG_BOT_NAME%60%0A*+Email%3A+%60some-email%40kind-company.com%60) requesting the bot user be added to this WordPress.org site as a "Test Reporter"**. The email address associated with the user is required.
3. After your bot user has been added, sign in to the Making WordPress Hosting site as the bot and visit `Users -> Your Profile` to generate an application password.
4. Set the application password as an environment variable: export REPORTER_API_KEY='wonderfulbot:Osho NHgM xYSY UWF9 qNUn YdjV'.

## What is measured?

The test runner measures the performance of 4 different approaches to data storage for the RTC feature.

|  # | Approach                                  | name                           | PR                                                                   |
|----|-------------------------------------------|--------------------------------|----------------------------------------------------------------------|
| 1  | Post meta — RC2 baseline                  | `post-meta`                    | NA                                                                   |
| 2  | Custom table for all data                 | `custom-table`                 | [#11256](https://github.com/WordPress/wordpress-develop/pull/11256)  |
| 3  | Post meta + transients for awareness      | `post-meta-transients`         | [#11348](https://github.com/WordPress/wordpress-develop/pull/11348)  |
| 4  | Custom table + object cache for awareness | `custom-table-with-transients` | [#11599](https://github.com/WordPress/wordpress-develop/pull/11599)  |
