package main

import (
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"os"
)

func main() {
	// Считываем переменные окружения с дефолтами
	targetDomain := os.Getenv("TARGET_DOMAIN")
	if targetDomain == "" {
		targetDomain = "https://default-domain.com"
	}

	apiPrefix := os.Getenv("API_PREFIX")
	if apiPrefix == "" {
		apiPrefix = "/api/"
	}

	listenPort := os.Getenv("LISTEN_PORT")
	if listenPort == "" {
		listenPort = "8080"
	}

	certFile := os.Getenv("CERT_FILE")
	if certFile == "" {
		certFile = "/etc/letsencrypt/live/your_domain/cert.pem"
	}

	keyFile := os.Getenv("KEY_FILE")
	if keyFile == "" {
		keyFile = "/etc/letsencrypt/live/your_domain/privkey.pem"
	}

	debugMode := os.Getenv("DEBUG_MODE")
	if debugMode == "" {
		debugMode = "False"
	}

	http.HandleFunc(apiPrefix, func(w http.ResponseWriter, r *http.Request) {
		// Логируем запрос
		requestDump, err := httputil.DumpRequest(r, true)
		if err != nil {
			http.Error(w, "Error reading request", 500)
			return
		}
		log.Println(string(requestDump))

		// Создаем новый запрос на основе пришедшего
		req, err := http.NewRequest(r.Method, targetDomain+r.RequestURI, r.Body)
		if err != nil {
			http.Error(w, "Error creating request", 500)
			return
		}

		// Копируем заголовки
		for name, values := range r.Header {
			for _, value := range values {
				req.Header.Add(name, value)
			}
		}

		// Выполняем запрос
		client := &http.Client{}
		resp, err := client.Do(req)
		if err != nil {
			http.Error(w, "Error making proxy request", 500)
			return
		}
		defer resp.Body.Close()

		// Копируем ответ
		for name, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})

	if debugMode == "True" {
		log.Println("Starting HTTP server on :" + listenPort)
		log.Fatal(http.ListenAndServe(":"+listenPort, nil))
	} else {
		log.Println("Starting HTTPS server on :" + listenPort)
		log.Fatal(http.ListenAndServeTLS(":"+listenPort, certFile, keyFile, nil))
	}
}
