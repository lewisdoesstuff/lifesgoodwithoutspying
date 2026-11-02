"""Parse ConnMan service properties as dbus-send prints them (webOS 4.x)."""
import os
from pathlib import Path
import re
import subprocess
import unittest


HANDOFF = Path(__file__).resolve().parents[1] / "dns-filter/scripts/tv-handoff.sh"

# GetProperties as webOS 4.4 prints it, trimmed and with made-up identifiers.
# "Address" appears three times: two MACs and the IPv4 address.
PROPERTIES = '''method return time=1793645315.969461 sender=:1.3 -> destination=:1.9 serial=1754 reply_serial=2
   array [
      dict entry(
         string "Type"
         variant             string "wifi"
      )
      dict entry(
         string "State"
         variant             string "online"
      )
      dict entry(
         string "Strength"
         variant             byte 79
      )
      dict entry(
         string "Name"
         variant             string "Test Network"
      )
      dict entry(
         string "WiFi.SSID"
         variant             array of bytes "Test Network"
      )
      dict entry(
         string "BSS"
         variant             array [
               struct {
                  array [
                     dict entry(
                        string "Id"
                        variant                            string "02:00:00:00:00:01"
                     )
                     dict entry(
                        string "Signal"
                        variant                            int32 -41
                     )
                  ]
               }
            ]
      )
      dict entry(
         string "Address"
         variant             string "02:00:00:00:00:01"
      )
      dict entry(
         string "Ethernet"
         variant             array [
               dict entry(
                  string "Method"
                  variant                      string "auto"
               )
               dict entry(
                  string "Interface"
                  variant                      string "wlan0"
               )
               dict entry(
                  string "Address"
                  variant                      string "02:00:00:00:00:02"
               )
            ]
      )
      dict entry(
         string "IPv4"
         variant             array [
               dict entry(
                  string "Method"
                  variant                      string "dhcp"
               )
               dict entry(
                  string "Address"
                  variant                      string "192.0.2.10"
               )
               dict entry(
                  string "Gateway"
                  variant                      string "192.0.2.1"
               )
            ]
      )
      dict entry(
         string "IPv4.Configuration"
         variant             array [
               dict entry(
                  string "Method"
                  variant                      string "dhcp"
               )
            ]
      )
      dict entry(
         string "IPv6"
         variant             array [
            ]
      )
      dict entry(
         string "Nameservers"
         variant             array [
               string "192.0.2.1"
               string "2001:db8::1"
            ]
      )
      dict entry(
         string "Nameservers.Configuration"
         variant             array [
               string "198.51.100.1"
            ]
      )
   ]
'''


def function_source(name):
    text = HANDOFF.read_text(encoding="utf-8")
    match = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
    if not match:
        raise AssertionError("%s() not found in %s" % (name, HANDOFF))
    return match.group(0)


def run(call, properties=PROPERTIES):
    script = function_source("dbus_send_property") + function_source("dbus_send_nameservers") + call
    out = subprocess.run(
        [os.environ.get("TEST_SHELL", "sh"), "-c", script],
        input=properties, capture_output=True, text=True, check=True,
    ).stdout
    return out.splitlines()


class DbusSendPropertyTest(unittest.TestCase):
    def test_top_level_state(self):
        self.assertEqual(run("dbus_send_property '' State"), ["online"])

    def test_interface_from_the_ethernet_section(self):
        self.assertEqual(run("dbus_send_property Ethernet Interface"), ["wlan0"])

    def test_ipv4_address_is_not_a_mac(self):
        self.assertEqual(run("dbus_send_property IPv4 Address"), ["192.0.2.10"])

    def test_section_key_is_not_read_at_the_top_level(self):
        self.assertEqual(run("dbus_send_property '' Interface"), [])

    def test_missing_section(self):
        self.assertEqual(run("dbus_send_property IPv6 Address"), [])

    def test_nameservers_skip_the_configuration_list(self):
        self.assertEqual(run("dbus_send_nameservers"), ["192.0.2.1", "2001:db8::1"])

    def test_no_nameservers(self):
        empty = PROPERTIES.replace(
            '               string "192.0.2.1"\n               string "2001:db8::1"\n', '')
        self.assertEqual(run("dbus_send_nameservers", empty), [])


if __name__ == "__main__":
    unittest.main()
