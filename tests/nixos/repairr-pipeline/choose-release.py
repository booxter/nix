"""Answer the Lidarr release question from the operator inbox."""

import sys

from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import Select, WebDriverWait

options = webdriver.ChromeOptions()
options.binary_location = "/run/current-system/sw/bin/chromium"
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.accept_insecure_certs = True  # The VM issues its own localhost certificate.
driver = Service("/run/current-system/sw/bin/chromedriver")

with webdriver.Chrome(service=driver, options=options) as browser:
    browser.implicitly_wait(10)
    browser.get("https://localhost/lidarr")
    choice = Select(browser.find_element(By.NAME, "choice"))
    choice.select_by_visible_text(sys.argv[1])
    browser.find_element(By.CSS_SELECTOR, ".response-form button").click()
    WebDriverWait(browser, 10).until(lambda page: page.current_url.endswith("/?submitted=1"))
