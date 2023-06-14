package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/Krognol/go-wolfram"
	"github.com/joho/godotenv"
	"github.com/shomali11/slacker"
	"github.com/stretchr/testify/assert"
	"github.com/tidwall/gjson"
	witai "github.com/wit-ai/wit-go"
	"io/ioutil"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"syscall"
	"testing"
)

var wolframClient *wolfram.Client

func printCommandEvents(analyticsChannel <-chan *slacker.CommandEvent) {
	for event := range analyticsChannel {
		fmt.Println("Command events")
		fmt.Println(event.Timestamp)
		fmt.Println(event.Command)
		fmt.Println(event.Parameters)
		fmt.Println(event.Event)
		fmt.Println()
	}
}
func TestSuite(t *testing.T) {
	tests := []struct {
		name string
		fn   func(*testing.T)
	}{
		{
			name: "TestBotCommandHandler",
			fn:   TestBotCommandHandler,
		},
		// Add more test cases if needed
	}

	for _, test := range tests {
		t.Run(test.name, test.fn)
	}
}

func main() {

	godotenv.Load(".env")

	bot := slacker.NewClient(os.Getenv("SLACK_BOT_TOKEN"), os.Getenv("SLACK_APP_TOKEN"))
	client := witai.NewClient(os.Getenv("WIT_AI_TOKEN"))
	wolframClient := &wolfram.Client{AppID: os.Getenv("WOLFRAM_APP_ID")}
	go printCommandEvents(bot.CommandEvents())

	bot.Command("query for bot - <message>", &slacker.CommandDefinition{
		Description: "send any question to wolfram",
		Examples:    []string{"what is the capital of india"},
		Handler: func(botContext slacker.BotContext, request slacker.Request, writer slacker.ResponseWriter) {
			query := request.Param("message")

			msg, err := client.Parse(&witai.MessageRequest{
				Query: query,
			})
			if err != nil {
				fmt.Println("Error parsing message:", err)
				writer.Reply("Sorry, I couldn't understand your query.")
				return
			}

			msgBytes, err := json.Marshal(msg)
			if err != nil {
				fmt.Println("Error marshaling message:", err)
				writer.Reply("An error occurred while processing your query.")
				return
			}
			msgString := string(msgBytes)
			capital := gjson.Get(msgString, "entities.wolfram_search_query.1.value").String()
			if capital == "" {
				writer.Reply("Sorry, I couldn't determine the location. wolfram")
				return
			}

			res, err := wolframClient.GetSpokentAnswerQuery(capital, wolfram.Metric, 1000)
			if err != nil {
				fmt.Println("Error retrieving spoken answer:", err)
				writer.Reply("An error occurred while processing your query.")
				return
			}

			writer.Reply(res)
		},
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	err := bot.Listen(ctx)

	if err != nil {
		log.Fatal(err)
	}

	TestSuite(nil)

	terminationSignal := make(chan os.Signal, 1)
	signal.Notify(terminationSignal, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-terminationSignal

		cancel()
	}()

	<-ctx.Done()
}

type TestResponseWriter struct {
	Buffer *bytes.Buffer
}

func (w *TestResponseWriter) Reply(text string) {
	w.Buffer.WriteString(text)
}

func TestBotCommandHandler(t *testing.T) {

	bot := slacker.NewClient("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN")

	bot.Command("greet - <name>", &slacker.CommandDefinition{
		Description: "Greet someone",
		Examples:    []string{"i am greeting you <name>"},
		Handler: func(botContext slacker.BotContext, request slacker.Request, response slacker.ResponseWriter) {
			name := request.StringParam("name", "friend")
			response.Reply(fmt.Sprintf("Hello, %s!", name))
		},
	})

	message := &slacker.MessageEvent{
		ChannelID: "C05CNLT12MP",
		UserID:    "U05CCET16FN",
		Text:      "greet Alice",
	}

	buffer := &bytes.Buffer{}

	fmt.Println(message)

	expectedResponse := "Hello, Alice!"
	if buffer.String() != expectedResponse {
		t.Errorf("Response mismatch: expected '%s', got '%s'", expectedResponse, buffer.String())
	}
}
func TestEndToEnd(t *testing.T) {

	server := httptest.NewServer(http.HandlerFunc(handleTestRequest))
	defer server.Close()

	os.Setenv("SLACK_BOT_TOKEN", "test_bot_token")
	os.Setenv("SLACK_APP_TOKEN", "test_app_token")

	bot := slacker.NewClient(os.Getenv("SLACK_BOT_TOKEN"), os.Getenv("SLACK_APP_TOKEN"))

	bot.Command("greet <name>", &slacker.CommandDefinition{
		Description: "Greet someone",
		Handler: func(botContext slacker.BotContext, request slacker.Request, response slacker.ResponseWriter) {
			name := request.StringParam("name", "friend")
			response.Reply(fmt.Sprintf("Hello, %s!", name))
		},
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		err := bot.Listen(ctx)
		if err != nil {
			t.Errorf("Error starting the bot: %v", err)
		}
	}()

	message := "greet Alice"
	url := fmt.Sprintf("%s/command?text=%s", server.URL, message)
	response, err := http.Get(url)
	if err != nil {
		t.Errorf("Error sending test request: %v", err)
		return
	}
	defer response.Body.Close()

	body, err := ioutil.ReadAll(response.Body)
	if err != nil {
		t.Errorf("Error reading response body: %v", err)
		return
	}

	expectedResponse := "Hello, Alice!"
	assert.Equal(t, expectedResponse, string(body))
}
func handleTestRequest(w http.ResponseWriter, r *http.Request) {

	text := r.URL.Query().Get("text")

	buffer := &bytes.Buffer{}
	response := &TestResponseWriter{Buffer: buffer}

	_, _ = fmt.Println(context.Background(), text, response)
	{
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	w.Write(buffer.Bytes())
}
