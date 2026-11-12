# Primeiros passos

*[English](GETTING_STARTED.md) | Português* · [Voltar ao README](../README-PTBR.md)

Este guia leva você de um projeto Godot vazio até um asset da Fab na sua cena, usando os formatos
glTF ou FBX, que funcionam em qualquer sistema (Linux, Windows e macOS).

> **Assets de Unreal Engine funcionam só no Linux por enquanto.** Converter pacotes `.uasset`
> exige o Unreal Engine 5.8 e um plugin compilado no Linux; veja [o README](../README-PTBR.md#commandlet-do-unrealtogodot-só-para-o-caminho-unreal)
> se quiser configurar. Tudo abaixo funciona sem o Unreal.

## 1. Instale o addon

1. Na [página do repositório](https://github.com/alextrevisan/GodotFab), clique em
   *Code → Download ZIP* e extraia em qualquer lugar.
2. Copie a pasta `addons/godotfab` dele para o seu projeto Godot 4.8. Deve ficar
   `res://addons/godotfab/plugin.cfg`.
3. Na Godot, abra *Project → Project Settings → Plugins* e ative o **GodotFab**.

Aparece uma aba **Fab** na barra superior do editor, ao lado de 2D, 3D e Script.

## 2. Faça login na Epic Games

Os downloads vêm da sua biblioteca Fab, então você precisa de uma conta Epic Games.

1. Na aba **Fab**, abra o menu (o ícone à direita da busca) e escolha **Log In to Epic Games…**.
2. Clique em **Open login page in browser** e faça login na página da Epic.
3. A página mostra um texto JSON com um `authorizationCode`. Copie só o código, cole no diálogo
   e clique em **Log In**.

O login fica salvo; só é preciso repetir se ele expirar.

## 3. Encontre um asset

1. Digite em **Search Fab assets** e aperte Enter. Marque **Free only** para ver só os gratuitos.
2. Clique numa miniatura para abrir os detalhes: descrição, formatos e preço.

A busca funciona sem login. Só aparecem assets que oferecem glTF, FBX ou Unreal Engine.

## 4. Adicione à sua biblioteca

A Fab só deixa baixar assets que estão na sua biblioteca.

- **Asset grátis:** clique em **Add on fab.com**. A página do asset abre no navegador; clique em
  *Add to My Library* lá, volte para a Godot e clique em **Refresh library**.
- **Asset pago:** clique em **Buy on fab.com** e compre no site.

Se você já clicou em **Download**, ele espera e continua sozinho quando o asset aparecer na
biblioteca.

## 5. Baixe

1. Nos detalhes do asset, clique em **Download**. Por padrão o addon escolhe glTF e depois FBX
   (*Settings → Preferred format*).
2. O progresso aparece no diálogo. Downloads interrompidos continuam de onde pararam.
3. Ao terminar, o asset fica em `res://fab_assets/<nome do asset>/`.

## 6. Use numa cena

- Clique em **Open Scene** nos detalhes do asset, ou abra o arquivo `.glb` / `.fbx` pelo
  FileSystem.
- Para colocar no seu nível, arraste o `.glb` / `.fbx` do FileSystem para a viewport 3D.
- Para editar o modelo importado, clique com o botão direito nele na cena e escolha
  *Make Local*, ou use *Scene → New Inherited Scene*.

## Próximos passos

- Configurações como a pasta de download ficam em menu → **Settings…**.
- Problemas de download (HTTP 403, termos da Fab, erro 429) estão em
  [Problemas comuns](../README-PTBR.md#problemas-comuns).
