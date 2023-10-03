package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/mem"
)

func main() {
	var startTime = time.Now()

	targetDomain := os.Getenv("TARGET_DOMAIN")
	listenPort := os.Getenv("LISTEN_PORT")
	loggingFlag := os.Getenv("LOGGING_FLAG")

	var httpsFlag string
	var statFlag bool
	flag.BoolVar(&statFlag, "stat", false, "Enable statistics")
	flag.StringVar(&httpsFlag, "https", "on", "Disable HTTPS if set to 'off'")
	flag.Parse()

	if targetDomain == "" {
		targetDomain = "default-domain.com"
	}
	if listenPort == "" {
		listenPort = "8888"
	}
	if loggingFlag == "" {
		loggingFlag = "off"
	}

	var (
		mu           sync.Mutex
		requests     int
		maxRPS       int
		minLatency   time.Duration
		maxLatency   time.Duration
		totalLatency time.Duration
		previousRPS  int
	)
	if statFlag {
		go func() {
			for {
				fmt.Print("\033[?25l")       // Скрыть курсор
				defer fmt.Print("\033[?25h") // Показать курсор при выходе
				time.Sleep(time.Second)

				// Получаем статистику CPU
				cpuPercent, _ := cpu.Percent(0, false)
				cpuLoad := cpuPercent[0]

				// Получаем статистику памяти
				memory, _ := mem.VirtualMemory()
				memUsage := memory.UsedPercent

				mu.Lock()
				rps := requests - previousRPS
				previousRPS = requests
				if rps > maxRPS {
					maxRPS = rps
				}
				avgLatency := "N/A"
				if requests > 0 {
					avgLatency = (totalLatency / time.Duration(requests)).String()
				}

				uptime := time.Since(startTime).Round(time.Second)

				// Оформляем значения в рамках, если нужно
				cpuStr := fmt.Sprintf("%.2f%%", cpuLoad)
				memStr := fmt.Sprintf("%.2f%%", memUsage)

				if cpuLoad > 70 {
					cpuStr = "[" + cpuStr + "]"
				}
				if memUsage > 70 {
					memStr = "[" + memStr + "]"
				}

				// Собираем всю статистику в одну строку
				stats := fmt.Sprintf("\r\033[35mUptime: %s\033[0m | \033[36mCurrent RPS: %d\033[0m | \033[35mMax RPS: %d\033[0m | \033[32mMin Latency: %s\033[0m | \033[34mMax Latency: %s\033[0m | \033[33mAvg Latency: %s\033[0m | \033[31mCPU: %s\033[0m | \033[32mRAM: %s\033[0m",
					uptime, rps, maxRPS, minLatency, maxLatency, avgLatency, cpuStr, memStr)

				padding := 150 - len(stats)
				if padding < 0 {
					padding = 0
				}
				fmt.Printf("%s%s", stats, strings.Repeat(" ", padding))
				mu.Unlock()
			}
		}()
	}

	proxy := httputil.NewSingleHostReverseProxy(&url.URL{
		Scheme: "https",
		Host:   targetDomain,
	})

	proxy.Director = func(req *http.Request) {
		start := time.Now()
		req.URL.Scheme = "https"
		req.URL.Host = targetDomain
		req.Host = targetDomain

		if loggingFlag == "on" {
			log.Printf("Forwarding request to: %s", req.URL.String())
			log.Printf("Request headers: %v", req.Header)
		}

		mu.Lock()
		requests++
		latency := time.Since(start)
		if latency > maxLatency {
			maxLatency = latency
		}
		if minLatency == 0 || latency < minLatency {
			minLatency = latency
		}
		totalLatency += latency
		mu.Unlock()
	}

	proxy.ModifyResponse = func(resp *http.Response) error {
		if loggingFlag == "on" {
			log.Printf("Received response with status code: %d", resp.StatusCode)
			log.Printf("Response headers: %v", resp.Header)
		}
		return nil
	}

	log.Printf("Target domain : [%s]", targetDomain)
	http.Handle("/", proxy)
	if httpsFlag == "off" {
		log.Printf("HTTPS mode disabled. Server running on : [%s]", listenPort)
		log.Fatal(http.ListenAndServe(":"+listenPort, nil))
	} else {
		certPath := os.Getenv("CERT_PATH") // Получаем путь к сертификату
		keyPath := os.Getenv("KEY_PATH")   // Получаем путь к ключу
		if certPath == "" || keyPath == "" {
			log.Fatal("CERT_PATH or KEY_PATH is not set")
		}

		// Настройки TLS
		tlsConfig := &tls.Config{
			// ... (другие опции, если нужны)
		}

		// HTTPS сервер
		server := &http.Server{
			Addr:      ":" + listenPort,
			Handler:   nil, // Используем http.DefaultServeMux
			TLSConfig: tlsConfig,
		}

		log.Printf("HTTPS mode enabled. Server running on : [%s]", listenPort)
		log.Fatal(server.ListenAndServeTLS(certPath, keyPath))
	}
}
